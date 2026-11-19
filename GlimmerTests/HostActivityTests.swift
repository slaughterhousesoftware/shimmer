import Foundation
import Testing
@testable import Glimmer

struct HostActivityTests {
    private static let now = Date(timeIntervalSince1970: 10_000)

    @Test func missingSessionInformationIsNotAnIdleHost() {
        let names = [3: "Steam Big Picture"]
        #expect(HostLiveStatus.reportedState(currentGameID: nil, appNamesByID: names) == .reachable)
        #expect(HostLiveStatus.reportedState(currentGameID: 0, appNamesByID: names) == .idle)
        #expect(HostLiveStatus.reportedState(currentGameID: 3, appNamesByID: names)
                == .streamingApp(name: "Steam Big Picture"))
        #expect(HostLiveStatus.reportedState(currentGameID: 4, appNamesByID: names)
                == .streamingUnknownApp(id: 4))
    }

    private static func host(_ id: String) -> Glimmer.Host {
        Glimmer.Host(id: id, name: id, customName: nil, localAddress: nil, manualAddress: nil,
                     apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil,
                     gfeVersion: nil, macAddress: nil)
    }

    @Test @MainActor func staleAndWrongHostSnapshotsCannotClaimAnAppIsRunning() {
        let model = AppModel()
        let host = Self.host("host-activity-a")
        model.selectedHost = host
        model.hostLiveStatus = HostLiveStatus(hostID: host.id,
                                             state: .streamingApp(name: "Steam Big Picture"),
                                             capturedAt: Self.now)
        #expect(model.hostStatusLine(for: host.id, at: Self.now) == "Online")
        #expect(model.hostStatusIndicator(for: host.id, at: Self.now) == .online)
        let expired = Self.now.addingTimeInterval(HostLiveStatus.stale + 1)
        #expect(model.hostStatusLine(for: host.id, at: expired) == "Checking…")
        #expect(model.hostStatusIndicator(for: host.id, at: expired) == .neutral)
        #expect(model.hostStatusLine(for: "other-host", at: Self.now) == "Checking…")
        #expect(model.hostStatusIndicator(for: "other-host", at: Self.now) == .neutral)
        #expect(model.liveStatus(for: "other-host", at: Self.now) == nil)
    }

    @Test @MainActor func transportReachabilityDoesNotClaimAnIdleSession() {
        let model = AppModel()
        let host = Self.host("host-activity-a")
        model.selectedHost = host
        model.hostLiveStatus = HostLiveStatus(hostID: host.id, state: .reachable, capturedAt: Self.now)
        #expect(model.hostStatusLine(for: host.id, at: Self.now) == "Online · status unavailable")
        #expect(model.hostStatusIndicator(for: host.id, at: Self.now) == .attention)
        #expect(model.runningAppName == nil)
        #expect(!HostLiveStatus.State.reachable.hasSessionInformation)
        #expect(HostLiveStatus.State.idle.hasSessionInformation)
    }

    @Test @MainActor func hostBadgesDistinguishOfflineTrustFailuresAndUnrelatedHosts() {
        let model = AppModel()
        let host = Self.host("badge-host")
        model.selectedHost = host
        model.hostLiveStatus = HostLiveStatus(hostID: host.id, state: .asleep, capturedAt: Self.now)
        #expect(model.hostStatusIndicator(for: host.id, at: Self.now) == .offline)
        model.hostLiveStatus?.state = .certMismatch
        #expect(model.hostStatusIndicator(for: host.id, at: Self.now) == .error)
        #expect(model.hostStatusLine(for: host.id, at: Self.now).contains("Trust needed"))
        model.nativeStreamError = "Decoder failed"
        #expect(model.hostStatusIndicator(for: host.id, at: Self.now) == .error)
        #expect(model.hostStatusIndicator(for: "other-host", at: Self.now) == .neutral)
        model.markStreamInterruption(hostID: host.id, at: Self.now)
        #expect(model.hostStatusIndicator(for: host.id, at: Self.now) == .offline)
    }

    /// A PS5 says whether it's resting; silence from one is just Offline. A
    /// PC that doesn't answer may be asleep or off - no telling which.
    @Test @MainActor func aRestingPS5IsInRestModeASilentOneOffline() {
        let model = AppModel()
        let ps5 = Self.host(Glimmer.Host.playStationIDPrefix + "test"), pc = Self.host("rest-pc")
        model.hosts = [ps5, pc]
        model.selectedHost = ps5
        model.hostLiveStatus = HostLiveStatus(hostID: ps5.id, state: .asleep, capturedAt: Self.now, restMode: true)
        #expect(model.hostStatusLine(for: ps5.id, at: Self.now) == "Rest mode")
        #expect(model.hostStatusIndicator(for: ps5.id, at: Self.now) == .offline)
        model.hostLiveStatus = HostLiveStatus(hostID: ps5.id, state: .asleep, capturedAt: Self.now)
        #expect(model.hostStatusLine(for: ps5.id, at: Self.now) == "Offline")
        model.selectedHost = pc
        model.hostLiveStatus = HostLiveStatus(hostID: pc.id, state: .asleep, capturedAt: Self.now)
        #expect(model.hostStatusLine(for: pc.id, at: Self.now) == "Asleep or offline")
        // The record a row shows once another machine is selected keeps it.
        model.recordReachability(from: HostLiveStatus(hostID: ps5.id, state: .asleep, capturedAt: Self.now,
                                                      restMode: true))
        #expect(model.sidebarStatusText(for: ps5.id, at: Self.now) == "Rest mode")
        model.recordReachability(false, for: ps5.id, at: Self.now)
        #expect(model.sidebarStatusText(for: ps5.id, at: Self.now) == "Offline")
    }

    /// The PS5 closing a live stream itself, with no controller on the Mac:
    /// the controller is on the console, signed in as the Remote Play
    /// account. Said, not a silent stop - and only then.
    @Test @MainActor func aPS5EndingTheStreamWithNoControllerHereSaysWhy() {
        let model = AppModel()
        let ps5 = Self.host(Glimmer.Host.playStationIDPrefix + "ended"), pc = Self.host("ended-pc")
        for (host, pad, expected) in [(ps5, false, true), (ps5, true, false), (pc, false, false)] {
            model.nativeStreamError = nil
            model.controllerConnected = pad
            model.isStreaming = true
            model.activeStreamHostID = host.id
            model.handleNativeEvent(.connectionTerminated(errorCode: 0), host: host)
            #expect((model.nativeStreamError?.contains("Connect the controller to this Mac") == true) == expected,
                    "\(host.id) pad \(pad)")
            model.isStreaming = false
        }
    }

    // Sony's own console names say nothing; a name someone chose does.
    @Test func onlySonysDefaultConsoleNamesAreGeneric() {
        for name in ["PS5-482", "PS5-001", "PS4-12"] { #expect(Glimmer.Host.isSonyDefaultName(name), "\(name)") }
        for name in ["Living Room", "PS5", "PS5-482 upstairs", "Kevin's PS5", "PS5-"] {
            #expect(!Glimmer.Host.isSonyDefaultName(name), "\(name)")
        }
        let ps5 = Glimmer.Host(id: Glimmer.Host.playStationIDPrefix + "x", name: "PS5-482",
                               customName: Glimmer.Host.genericPlayStationName, localAddress: nil, manualAddress: nil,
                               apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, gfeVersion: nil,
                               macAddress: nil)
        #expect(ps5.hasGenericPlayStationName && ps5.displayName == "PlayStation")
        #expect(!Self.host("pc").hasGenericPlayStationName)
    }

    // Just after a stream ends, before the server's next status: a spinner,
    // not an empty menu bar.
    @Test @MainActor func theMenuBarSpinsRatherThanEmptiesWhileTheServerIsAskedAgain() {
        let model = AppModel()
        guard model.menuBarControllerKind == nil else { return }   // a pad would show instead
        #expect(model.menuBarPresentation == nil)
        model.awaitingStatusAfterStream = true
        #expect(model.menuBarPresentation?.spinning == true)
        model.awaitingStatusAfterStream = false
        #expect(model.menuBarPresentation == nil)
    }

    @Test @MainActor func connectionProgressIsNotAStreamingClaimAndBelongsToOneHost() {
        let model = AppModel()
        model.isStreaming = true
        model.activeStreamHostID = "host-activity-a"
        model.streamPhase = .connecting(stage: "Connecting to Bazzite…")
        #expect(model.hostStatusLine(for: "host-activity-a") == "Connecting to Bazzite…")
        #expect(model.hostStatusIndicator(for: "host-activity-a") == .attention)
        #expect(model.hostStatusLine(for: "other-host") == "Checking…")
        model.streamPhase = .streaming
        #expect(model.hostStatusLine(for: "host-activity-a") == "Streaming")
        #expect(model.hostStatusIndicator(for: "host-activity-a") == .online)
        model.streamPhase = .connecting(stage: "Reconnecting to Bazzite…")
        #expect(model.hostStatusLine(for: "host-activity-a") == "Reconnecting to Bazzite…")
        model.isStreaming = false
    }

    @Test @MainActor func onlyAStreamWithVideoUpdatesHistoryAndAllHostCopiesImmediately() throws {
        let suite = "shimmer-host-activity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel()
        let host = Self.host("host-activity-a")
        let other = Self.host("host-activity-b")
        model.hosts = [other, host]
        model.selectedHost = host
        model.isStreaming = true
        model.activeStreamHostID = host.id
        model.streamPhase = .connecting(stage: "Connecting…")

        // A failed attempt or handshake alone must not fabricate history.
        model.recordStreamActivity(for: host.id, endedAt: Self.now, defaults: defaults)
        #expect(defaults.object(forKey: AppModel.lastStreamedKey(for: host.id)) == nil)
        model.handleNativeEvent(.connectionEstablished, host: host)
        model.recordStreamActivity(for: host.id, endedAt: Self.now, defaults: defaults)
        #expect(defaults.object(forKey: AppModel.lastStreamedKey(for: host.id)) == nil)
        model.markStreamVideo(for: other.id)
        #expect(!model.activeStreamHasVideo)

        model.handleNativeEvent(.firstFrame, host: host)
        #expect(model.lastStreamedDescription(for: host) == "Now")
        model.recordStreamActivity(for: host.id, endedAt: Self.now, defaults: defaults)
        #expect(defaults.object(forKey: AppModel.lastStreamedKey(for: host.id)) as? Date == Self.now)
        #expect(model.selectedHost?.lastStreamed == Self.now)
        #expect(model.hosts.first?.id == host.id)
        #expect(model.hosts.first?.lastStreamed == Self.now)
        #expect(model.hosts.first(where: { $0.id == other.id })?.lastStreamed == nil)
        model.isStreaming = false
    }

    @Test @MainActor func oldAttemptHistoryAndLateFramesCannotBecomeVerifiedHistory() {
        let model = AppModel()
        var host = Self.host("host-activity-a")
        host.lastConnected = Self.now
        model.selectedHost = host
        #expect(model.lastStreamedDescription(for: host, at: Self.now) == "Not recorded")
        model.activeStreamHostID = host.id
        model.isStreaming = true
        model.streamPhase = .idle
        model.markStreamVideo(for: host.id)
        #expect(!model.activeStreamHasVideo)
        model.isStreaming = false
        model.streamPhase = .streaming
        model.markStreamVideo(for: host.id)
        #expect(!model.activeStreamHasVideo)
    }

    @Test func relativeHistoryAgesWithTheClock() {
        var host = Self.host("host-activity-a")
        host.lastStreamed = Self.now
        let near = host.lastStreamedDescription(relativeTo: Self.now.addingTimeInterval(60))
        let later = host.lastStreamedDescription(relativeTo: Self.now.addingTimeInterval(7_200))
        #expect(near != nil)
        #expect(later != near)
    }
}

/// The sidebar's status dots come from the app model, not the Servers page,
/// so they survive switching tabs (and closing the window): a machine that
/// was green stays green instead of going grey until it's checked again.
@MainActor
struct SidebarReachabilityTests {
    private static let now = Date(timeIntervalSince1970: 50_000)
    private static let keys = ["glimmer.selectedHostID"]

    private static func host(_ id: String) -> Glimmer.Host {
        Glimmer.Host(id: id, name: id, customName: nil, localAddress: nil, manualAddress: nil,
                     apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil,
                     gfeVersion: nil, macAddress: nil)
    }

    private static func preservingDefaults(_ body: () -> Void) {
        let d = UserDefaults.standard
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        defer { for (key, value) in saved { d.set(value, forKey: key) } }
        body()
    }

    @Test func aRecordedCheckLivesInTheModel() {
        let model = AppModel()
        model.recordReachability(true, for: "pc-x", at: Self.now)
        #expect(model.sidebarIndicator(for: "pc-x", at: Self.now.addingTimeInterval(5)) == .online)
        #expect(model.sidebarStatusText(for: "pc-x", at: Self.now.addingTimeInterval(5)) == "Online")
        model.recordReachability(false, for: "pc-x", at: Self.now)
        #expect(model.sidebarIndicator(for: "pc-x", at: Self.now) == .offline)
    }

    @Test func anOldCheckGoesGrey() {
        let model = AppModel()
        model.recordReachability(true, for: "pc-x", at: Self.now)
        let later = Self.now.addingTimeInterval(HostLiveStatus.stale + 1)
        #expect(model.sidebarIndicator(for: "pc-x", at: later) == .neutral)
        #expect(model.sidebarStatusText(for: "pc-x", at: later) == "Checking…")
    }

    /// Just selected, its own status not in yet: the last check shows, not grey.
    @Test func aJustSelectedMachineKeepsItsLastCheck() {
        Self.preservingDefaults {
            let model = AppModel()
            let pc = Self.host("pc-sel-\(UUID().uuidString)")
            model.selectHost(pc)
            model.hostLiveStatus = nil
            model.recordReachability(true, for: pc.id, at: .now)
            #expect(model.sidebarIndicator(for: pc.id) == .online)
        }
    }

    /// The selected machine's own status feeds the same record, so it stays
    /// green when another machine is selected.
    @Test func theSelectedMachinesStatusIsRecorded() {
        let model = AppModel()
        model.recordReachability(from: HostLiveStatus(hostID: "pc-y", state: .idle, capturedAt: Self.now))
        #expect(model.sidebarIndicator(for: "pc-y", at: Self.now) == .online)
        model.recordReachability(from: HostLiveStatus(hostID: "pc-y", state: .asleep, capturedAt: Self.now))
        #expect(model.sidebarIndicator(for: "pc-y", at: Self.now) == .offline)
    }
}
