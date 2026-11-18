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
            probedAddress: console.address, probedAt: started), expectedHostID: host.id)
    }

    // MARK: Stream

    /// Wake the console if it is in rest mode, then stream. Wake takes the PS5
    /// about 15-25 s; the connecting capsule shows it.
    func requestPlayStationStream(on host: Host) {
        guard let console = playStationConsole(for: host) else {
            nativeStreamError = "This PlayStation isn't registered anymore. Add it again in Settings."
            return
        }
        Task { [weak self] in
            var console = console
            var status = await PlayStationDiscovery.probe(address: console.address)
            if status == nil, let moved = await self?.relocatePlayStation(console) {
                console = moved
                status = await PlayStationDiscovery.probe(address: console.address)
            }
            if status?.power != .ready {
                guard let self else { return }
                self.streamPhase = .connecting(stage: "Waking \(console.nickname)…")
                Diag.notice("PS5: \(console.nickname) is \(status == nil ? "not answering" : "in rest mode") - waking it", "PlayStation")
                PlayStationDiscovery.wake(console: console)
                let awake = await PlayStationDiscovery.waitUntilReady(address: console.address, timeout: 40)
                if !awake {
                    Diag.error("PS5: \(console.nickname) did not wake within 40 s", "PlayStation")
                }
            }
            self?.stream(app: .playStationHome, on: host)
        }
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
