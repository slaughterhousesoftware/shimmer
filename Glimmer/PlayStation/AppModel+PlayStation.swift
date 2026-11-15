//
//  AppModel+PlayStation.swift
//
//  How a registered PS5 joins the app: it is listed as a host (id "ps5-<mac>")
//  with one launchable entry, its status chip comes from PlayStation discovery
//  instead of /serverinfo, a console in rest mode is woken before connecting,
//  and the stream runs on PlayStationBackend. Sunshine-only paths (pairing,
//  /applist, the takeover check, in-place reconnect) skip PS5 hosts.
//

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

    /// Video settings for a PS5 stream, from the user's stream settings: the
    /// console offers 720p or 1080p at 30 or 60 fps.
    func playStationStreamOptions() -> PlayStationStreamOptions {
        var options = PlayStationStreamOptions()
        options.resolution = effectiveHeight > 720 ? .p1080 : .p720
        options.fps = effectiveFPS > 30 ? 60 : 30
        return options
    }

    // MARK: Status

    /// One discovery probe → the readiness chip. "ready" = on and idle or
    /// running a game (named when the console says which); "standby" = rest
    /// mode, which the chip shows as asleep (Stream wakes it).
    func pollPlayStationStatusOnce(host: Host) async {
        guard let console = playStationConsole(for: host) else { return }
        let started = Date()
        let status = await PlayStationDiscovery.probe(address: console.address)
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
            let status = await PlayStationDiscovery.probe(address: console.address)
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

    /// The backend for a session on `host`: PS5 hosts get libchiaki, every
    /// other host the GameStream engine.
    func makeStreamingBackend(for host: Host) -> StreamingBackend {
        if host.isPlayStation, let console = playStationConsole(for: host) {
            return PlayStationBackend(console: console, options: playStationStreamOptions())
        }
        return NativeBackend()
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
