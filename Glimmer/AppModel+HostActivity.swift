import Foundation

enum HostStatusIndicator {
    case neutral, online, attention, offline, error
}

/// One online check of a machine, for its sidebar dot.
struct HostReachabilitySample: Equatable {
    let reachable: Bool
    let capturedAt: Date
    /// Not reachable for streaming, but answering: a PS5 in rest mode.
    var restMode = false

    func isFresh(at now: Date) -> Bool { now.timeIntervalSince(capturedAt) <= HostLiveStatus.stale }
}

extension AppModel {
    func recordReachability(_ reachable: Bool, for hostID: String, at now: Date = .now, restMode: Bool = false) {
        hostReachability[hostID] = HostReachabilitySample(reachable: reachable, capturedAt: now, restMode: restMode)
    }

    /// The selected machine's own status counts as a check too, so it stays
    /// green once another machine is selected.
    func recordReachability(from live: HostLiveStatus) {
        switch live.state {
        case .unknown: return
        case .asleep: recordReachability(false, for: live.hostID, at: live.capturedAt, restMode: live.restMode)
        case .idle, .reachable, .streamingApp, .streamingUnknownApp, .certMismatch:
            recordReachability(true, for: live.hostID, at: live.capturedAt)
        }
    }

    private func freshReachability(for hostID: String, at now: Date) -> HostReachabilitySample? {
        hostReachability[hostID].flatMap { $0.isFresh(at: now) ? $0 : nil }
    }

    /// The selected (or streaming) machine shows its own detailed status;
    /// until that's in, and for every other machine, its last online check.
    private func showsOwnStatus(_ hostID: String) -> Bool {
        selectedHost?.id == hostID || (isStreaming && activeStreamHostID == hostID)
    }

    /// A machine's sidebar dot.
    func sidebarIndicator(for hostID: String, at now: Date = .now) -> HostStatusIndicator {
        if showsOwnStatus(hostID) {
            let own = hostStatusIndicator(for: hostID, at: now)
            if own != .neutral || (isStreaming && activeStreamHostID == hostID) { return own }
        }
        guard let sample = freshReachability(for: hostID, at: now) else { return .neutral }
        return sample.reachable ? .online : .offline
    }

    /// The words behind a machine's sidebar dot (its tooltip).
    /// `ignoringStreamError`: the machine's own state even while a failed
    /// stream's error stands (the menu shows that error in a row of its own).
    func sidebarStatusText(for hostID: String, at now: Date = .now, ignoringStreamError: Bool = false) -> String {
        if showsOwnStatus(hostID) {
            let own = hostStatusLine(for: hostID, at: now, ignoringStreamError: ignoringStreamError)
            if own != "Checking…" { return own }
        }
        guard let sample = freshReachability(for: hostID, at: now) else { return "Checking…" }
        return sample.reachable ? "Online" : notAnsweringText(for: hostID, restMode: sample.restMode)
    }

    /// A machine that can't stream now. A PS5 says whether it's resting
    /// (discovery answers "standby") or there's no answer at all; a PC that
    /// doesn't answer may be asleep or off, and there's no telling which.
    private func notAnsweringText(for hostID: String, restMode: Bool) -> String {
        if restMode { return "Rest mode" }
        return hosts.first { $0.id == hostID }?.isPlayStation == true ? "Offline" : "Asleep or offline"
    }

    /// One freshness/identity check for the status text and launch target.
    func liveStatus(for hostID: String, at now: Date = .now) -> HostLiveStatus? {
        guard let live = hostLiveStatus, live.hostID == hostID,
              now.timeIntervalSince(live.capturedAt) <= HostLiveStatus.stale else { return nil }
        return live
    }

    var selectedHostStatusLine: String {
        guard let id = selectedHost?.id else { return "No PC selected" }
        return hostStatusLine(for: id)
    }

    func hostStatusLine(for hostID: String, at now: Date = .now, ignoringStreamError: Bool = false) -> String {
        if isStreaming, activeStreamHostID == hostID {
            switch streamPhase {
            case .connecting(let stage): return stage
            case .streaming:
                return activeStreamShorthand.map { "Streaming at \($0)" } ?? "Streaming"
            case .idle, .disconnecting: return "Disconnecting…"
            case .error: return "Stream interrupted"
            }
        }
        if !ignoringStreamError, streamErrorAffectsStatus(of: hostID) {
            return interruptedStreamHost?.id == hostID ? "Connection interrupted" : "Connection needs attention"
        }
        guard let live = liveStatus(for: hostID, at: now) else { return "Checking…" }
        switch live.state {
        case .idle: return "Online"
        case .reachable: return "Online · status unavailable"
        case .streamingApp: return "Online"
        case .streamingUnknownApp: return "Online"
        case .asleep: return notAnsweringText(for: hostID, restMode: live.restMode)
        case .certMismatch: return "Trust needed - pair again"
        case .unknown: return "Checking…"
        }
    }

    func hostStatusIndicator(for hostID: String, at now: Date = .now) -> HostStatusIndicator {
        if isStreaming, activeStreamHostID == hostID {
            switch streamPhase {
            case .streaming: return .online
            case .connecting: return .attention
            case .error: return .error
            case .idle, .disconnecting: return .neutral
            }
        }
        if streamErrorAffectsStatus(of: hostID) {
            return interruptedStreamHost?.id == hostID ? .offline : .error
        }
        guard let live = liveStatus(for: hostID, at: now) else { return .neutral }
        switch live.state {
        case .idle, .streamingApp, .streamingUnknownApp: return .online
        case .reachable: return .attention
        case .unknown: return .neutral
        case .asleep: return .offline
        case .certMismatch: return .error
        }
    }

    static func lastStreamedKey(for hostID: String) -> String {
        "glimmer.lastStreamed.\(hostID)"
    }

    func lastStreamedDescription(for host: Host, at now: Date = .now) -> String {
        if isStreaming, activeStreamHostID == host.id, activeStreamHasVideo {
            if streamPhase == .streaming { return "Now" }
            if case .connecting = streamPhase { return "Reconnecting…" }
        }
        return host.lastStreamedDescription(relativeTo: now) ?? "Not recorded"
    }

    func markStreamVideo(for hostID: String) {
        guard isStreaming, activeStreamHostID == hostID else { return }
        switch streamPhase {
        case .connecting, .streaming: activeStreamHasVideo = true
        case .idle, .disconnecting, .error: break
        }
    }

    /// Update persistence AND observable host copies before returning to the
    /// launcher. The old defaults-only write left the UI stale until reload.
    func recordStreamActivity(for hostID: String, endedAt date: Date = .now,
                              defaults: UserDefaults = .standard) {
        guard activeStreamHostID == hostID, activeStreamHasVideo else { return }
        if let console = hosts.first(where: { $0.id == hostID && $0.isPlayStation })
            .flatMap(playStationConsole(for:)) {
            PlayStationStore.shared.markStreamed(id: console.id)
        }
        defaults.set(date, forKey: Self.lastStreamedKey(for: hostID))
        defaults.set(date, forKey: "glimmer.lastConnected.\(hostID)")
        if let index = hosts.firstIndex(where: { $0.id == hostID }) {
            hosts[index].lastStreamed = date
            hosts[index].lastConnected = date
            hosts.sort { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
        }
        if selectedHost?.id == hostID {
            selectedHost?.lastStreamed = date
            selectedHost?.lastConnected = date
        }
    }
}
