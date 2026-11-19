//
//  AppModel+PlayStation.swift
//
//  How a registered PS5 joins the app: it is listed as a host (id "ps5-<mac>")
//  with one launchable entry, its status chip comes from PlayStation discovery
//  instead of /serverinfo, a console in rest mode is woken before connecting,
//  and the stream runs on PlayStationBackend. Sunshine-only paths (pairing,
//  /applist, the takeover check, in-place reconnect) skip PS5 hosts.
//

import AppKit
import Foundation
import Network

extension Host {
    static let playStationIDPrefix = "ps5-"
    var isPlayStation: Bool { id.hasPrefix(Self.playStationIDPrefix) }
}

extension LibraryApp {
    /// The one launchable entry of a PS5 host: the console itself.
    static let playStationHome = LibraryApp(id: 1, name: "PlayStation 5", hdr: false, hidden: false)
}

extension AppModel {
    /// Registered consoles as hosts, for the library and the menu bar.
    func playStationHosts() -> [Host] {
        PlayStationStore.shared.consoles.map { console in
            Host(
                id: console.hostID,
                name: console.nickname,
                customName: nil,
                localAddress: console.address,
                manualAddress: nil,
                apps: [.playStationHome],
                lastConnected: console.lastStreamed,
                serverCertPEM: nil,
                appVersion: nil,
                gfeVersion: nil,
                macAddress: console.id,
                lunaDeviceId: nil,
                lastStreamed: console.lastStreamed)
        }
    }

    func playStationConsole(for host: Host) -> PlayStationConsole? {
        PlayStationStore.shared.console(hostID: host.id)
    }

    /// A PS5 stream's settings: the PlayStation tab's own (PlayStationSettings),
    /// not the Sunshine ones. The console offers 720p or 1080p at 30 or 60 fps.
    /// Bitrate: automatic keeps the console's preset (15 Mbps at 1080p) and
    /// lets it adapt; one set by hand is sent as is (2-100 Mbps) and held.
    /// HDR only with HEVC, and only when this display can show it.
    func playStationStreamOptions(for host: Host) -> PlayStationStreamOptions {
        let s = PlayStationSettings.forConsole(host.id).snapshot
        var options = PlayStationStreamOptions()
        options.settings = s
        options.resolution = s.height > 720 ? .p1080 : .p720
        options.fps = s.fps > 30 ? 60 : 30
        if let kbps = s.bitrateKbps {
            options.bitrateKbps = PlayStationStreamOptions.clampBitrate(kbps)
            options.holdBitrate = true
        } else if options.resolution == .p1080 {
            options.bitrateKbps = PlayStationSettings.presetBitrateMbps * 1000   // adaptive, not held
        }
        let displayCanShowHDR = (NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        options.codec = !s.hevc ? .h264 : (s.hdr && displayCanShowHDR ? .h265HDR : .h265)
        options.extraPlayerAccounts = PlayStationSettings.extraPlayerAccounts
        return options
    }

    // MARK: Status

    /// One discovery probe → the readiness chip. "ready" = on and idle or
    /// running a game (named when the console says which); "standby" = rest
    /// mode, which the chip shows as asleep (Stream wakes it).
    func pollPlayStationStatusOnce(host: Host) async {
        guard var console = playStationConsole(for: host) else { return }
        let started = Date()
        var status = await PlayStationDiscovery.probe(address: console.address)
        if status == nil, let moved = await relocatePlayStation(console) {
            console = moved
            status = await PlayStationDiscovery.probe(address: console.address)
        }
        let rttMs = Int(Date().timeIntervalSince(started) * 1000)
        let state: HostLiveStatus.State
        switch status?.power {
        case .ready?:
            if let app = status?.runningApp, !app.isEmpty {
                state = .streamingApp(name: app)
            } else {
                state = .idle
            }
        case .standby?: state = .asleep
        default: state = .asleep
        }
        await publishLiveStatus(HostLiveStatus(
            hostID: host.id, state: state, rttMs: status == nil ? nil : rttMs,
            sunshineVersion: status?.systemVersion, capturedAt: Date(),
            probedAddress: console.address, probedAt: started, restMode: status?.power == .standby),
            expectedHostID: host.id)
    }

    // MARK: Stream

    /// Stream a PS5. Finding it and waking it from rest mode are the stream
    /// attempt's own first step (`readyPlayStation`), so the row shows
    /// "Waking…" with a Cancel beside it, a second click is the same attempt,
    /// and End Stream or a switch to another machine stops it.
    func requestPlayStationStream(on host: Host) {
        guard playStationConsole(for: host) != nil else {
            nativeStreamError = "This PlayStation isn't registered anymore. Add it again in Settings."
            streamErrorHostID = host.id
            return
        }
        stream(app: .playStationHome, on: host)
    }

    /// The first step of a PS5 stream: find the console (its address may have
    /// changed) and wake it if it rests. Wake takes the PS5 about 15-25 s.
    /// Returns whether the console answered discovery at all; throws
    /// `.didNotWake` when it answered as resting and never came up, and
    /// `.cancelled` when the attempt was stopped meanwhile.
    func readyPlayStation(_ host: Host, token: UUID) async throws -> Bool {
        guard var console = playStationConsole(for: host) else {
            throw StreamError.playStation(.unreachable("not registered"))
        }
        var status = await PlayStationDiscovery.probe(address: console.address)
        if status == nil, !Task.isCancelled, let moved = await relocatePlayStation(console) {
            console = moved
            status = await PlayStationDiscovery.probe(address: console.address)
        }
        if Task.isCancelled { throw StreamError.cancelled }
        guard status?.power != .ready else { return true }
        let answered = status != nil
        // On the home network a PS5 always answers discovery while it rests,
        // and only a resting one can be woken: silence there means it's off
        // (or unplugged, or resting with its network features off), and no
        // wake or session will reach it. Say so now, not after a 40 s wake
        // and a session timeout. (Over a route that filters discovery - a
        // VPN - silence proves nothing, so that still goes on to try.)
        if !answered, Self.isHomeNetworkAddress(console.address) {
            Diag.notice("PS5: \(console.nickname) didn't answer discovery on the home network - not trying further",
                        "PlayStation")
            throw StreamError.playStation(.unreachable("no discovery answer on the home network"))
        }
        if currentStreamToken == token, case .connecting(let stage) = streamPhase, stage != Self.cancellingStage {
            streamPhase = .connecting(stage: "Waking \(console.nickname)…")
        }
        Diag.notice("PS5: \(console.nickname) is \(answered ? "in rest mode" : "not answering") - waking it", "PlayStation")
        let awake = await PlayStationDiscovery.wakeAndWait(console: console, timeout: Self.playStationWakeSeconds)
        if Task.isCancelled { throw StreamError.cancelled }
        if awake {
            if currentStreamToken == token, case .connecting(let stage) = streamPhase, stage != Self.cancellingStage {
                streamPhase = .connecting(stage: "Connecting to \(host.displayName)…")
            }
            return true
        }
        Diag.error("PS5: \(console.nickname) did not wake within \(Int(Self.playStationWakeSeconds)) s", "PlayStation")
        // It said it was resting and never came up: a session can't start.
        // One that never answered discovery may still take a session (a route
        // that filters discovery), so that one goes on to try.
        if answered { throw StreamError.playStation(.didNotWake) }
        return false
    }

    nonisolated static let playStationWakeSeconds: TimeInterval = 40

    /// A private LAN address (10/8, 172.16/12, 192.168/16, link-local) -
    /// where discovery reaches a resting PS5. Not Tailscale's 100.64/10.
    nonisolated static func isHomeNetworkAddress(_ address: String) -> Bool {
        guard let ip = IPv4Address(address) else { return false }
        let b = [UInt8](ip.rawValue)
        return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
            || (b[0] == 169 && b[1] == 254)
    }

    /// What the failure of a PS5 attempt means given whether the console ever
    /// answered discovery: "on but not answering" is only true of one that did.
    nonisolated static func playStationFailure(_ error: Error, answeredDiscovery: Bool) -> Error {
        if case StreamError.playStation(.noAnswer) = error, !answeredDiscovery {
            return StreamError.playStation(.unreachable("no discovery answer, no session"))
        }
        return error
    }

    /// The saved address didn't answer: look for the console on the LAN (a new
    /// DHCP lease, or Ethernet instead of Wi-Fi) and remember where it is now.
    /// Matches the discovery host-id first, then the console's name, since a
    /// wired PS5 can report a different host-id than it did on Wi-Fi.
    func relocatePlayStation(_ console: PlayStationConsole) async -> PlayStationConsole? {
        let found = await PlayStationDiscovery.scan()
        guard let match = found.first(where: { $0.id.lowercased() == console.id })
                ?? found.first(where: { $0.name == console.nickname }),
              match.address != console.address else { return nil }
        Diag.notice("PS5: \(console.nickname) moved to a new address; using it from now on", "PlayStation")
        PlayStationStore.shared.updateAddress(id: console.id, address: match.address)
        loadHosts()
        return PlayStationStore.shared.consoles.first { $0.id == console.id }
    }

    /// The backend for a session on `host`: PS5 hosts get libchiaki, every
    /// other host the GameStream engine.
    func makeStreamingBackend(for host: Host) -> StreamingBackend {
        if host.isPlayStation, let console = playStationConsole(for: host) {
            return PlayStationBackend(console: console, options: playStationStreamOptions(for: host))
        }
        return NativeBackend(controllerFeedback: ControllerSettings.shared.snapshot)
    }

    // MARK: Library edits

    func forgetPlayStation(_ host: Host) {
        guard let console = playStationConsole(for: host) else { return }
        PlayStationStore.shared.remove(id: console.id)
        loadHosts()
    }

    func renamePlayStation(_ host: Host, to name: String) {
        guard var console = playStationConsole(for: host) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        console.nickname = trimmed
        PlayStationStore.shared.upsert(console)
        loadHosts()
    }
}
