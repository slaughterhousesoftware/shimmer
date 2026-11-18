import Foundation
import Testing
@testable import Glimmer

/// What the user is told when a stream doesn't start, and what a stream that
/// was stopped while starting leaves behind. One sentence used to cover every
/// failure ("Couldn't reach X. Make sure it's awake…"), including ones where
/// the machine had answered and the fix was a firewall, a re-pair, or another
/// device holding the console.
struct StreamFailureCopyTests {
    private let asleep = "Couldn't reach Den PC. Make sure it's awake and on the same network."

    @Test func aPcThatIsOffKeepsTheAwakeAdvice() {
        #expect(StreamFailureCopy.connect(StreamError.hostUnreachable("offline"), hostName: "Den PC") == asleep)
        #expect(StreamFailureCopy.connect(StreamError.truncatedRead("eof"), hostName: "Den PC") == asleep)
        #expect(StreamFailureCopy.connect(POSIXError(.ENETUNREACH), hostName: "Den PC") == asleep)
    }

    @Test func aPcThatAnsweredIsNeverToldToWakeUp() {
        let failures: [ConnectFailure] = [
            .streamPortUnreachable(port: 48010), .streamPortUnreachable(port: 0), .controlUnreachable,
            .hostRefused(step: "PLAY", code: 503), .hostWentQuiet, .unsupported("no SDP"),
            .localSockets("bind: EADDRINUSE"), .timedOut,
        ]
        var seen = Set<String>()
        for failure in failures {
            let text = StreamFailureCopy.connect(StreamError.connectFailed(failure), hostName: "Den PC")
            #expect(!text.contains("awake"), "\(failure) → \(text)")
            #expect(!text.contains("EADDRINUSE") && !text.contains("SDP"), "raw detail leaked: \(text)")
            seen.insert(text)
        }
        // Each cause has its own sentence, bar the two port spellings.
        #expect(seen.count == failures.count)
        #expect(StreamFailureCopy.connect(.streamPortUnreachable(port: 48010), hostName: "Den PC")
            .contains("TCP 48010"))
        #expect(StreamFailureCopy.connect(.hostRefused(step: "PLAY", code: 503), hostName: "Den PC")
            .contains("PLAY returned 503"))
    }

    @Test func everyPs5RefusalNamesItsOwnFix() {
        let failures: [(PlayStationFailure, String)] = [
            (.inUse, "in use by another device"),
            (.registrationRejected, "add it again"),
            (.accountNotRecognised, "account"),
            (.passcodeRequired, "passcode"),
            (.remotePlayCrashed, "Restart the PS5"),
            (.versionMismatch, "Update Shimmer"),
            (.didNotWake, "didn't wake up"),
            (.noAnswer, "Remote Play is enabled"),
            (.unreachable("no answer"), "plugged in"),
        ]
        var seen = Set<String>()
        for (failure, expected) in failures {
            let text = StreamFailureCopy.connect(StreamError.playStation(failure), hostName: "PS5-661")
            #expect(text.contains(expected), "\(failure) → \(text)")
            #expect(text.contains("PS5-661"))
            seen.insert(text)
        }
        #expect(seen.count == failures.count)
    }

    @Test func aLaunchFailureShowsWhatThePcSaid() {
        let said = StreamError.launchFailed(
            "Failed to initialize video capture/encoding. Is a display connected and turned on? (code 503)")
        #expect(StreamFailureCopy.connect(said, hostName: "Den PC")
            == "Den PC couldn't start the app: Failed to initialize video capture/encoding. Is a display connected and turned on?")
        // Our own descriptions of a broken reply are not the PC's words.
        for ours in ["HTTP 500 on /launch", "Malformed XML on /launch: line 3", "Response missing <root> element",
                     "Host did not return an RTSP session URL", "Status -1 (code -1)"] {
            let text = StreamFailureCopy.connect(StreamError.launchFailed(ours), hostName: "Den PC")
            #expect(text == "Den PC answered but couldn't start the app. It may already be in use.", "\(ours) → \(text)")
        }
        #expect(StreamFailureCopy.connect(StreamError.launchFailed("Host didn't respond within 22s - giving up."),
                                          hostName: "Den PC") == "Den PC took too long to start the app. Try again.")
    }

    @Test func onlyFailuresTheUserMustFixRaiseTheTriangle() {
        let waitsItOut: [StreamError] = [
            .hostUnreachable("offline"), .sessionFailed(-1), .cancelled,
            .connectFailed(.hostWentQuiet), .connectFailed(.timedOut),
            .playStation(.inUse), .playStation(.didNotWake), .playStation(.noAnswer), .playStation(.unreachable("")),
        ]
        for error in waitsItOut { #expect(StreamFailureCopy.isTransient(error), "\(error)") }
        let needsTheUser: [StreamError] = [
            .connectFailed(.streamPortUnreachable(port: 48010)), .connectFailed(.controlUnreachable),
            .connectFailed(.hostRefused(step: "PLAY", code: 503)), .connectFailed(.unsupported("x")),
            .playStation(.registrationRejected), .playStation(.accountNotRecognised),
            .playStation(.passcodeRequired), .playStation(.versionMismatch), .playStation(.remotePlayCrashed),
            .pairingRejected, .decoderFailed("x"), .launchFailed("x"),
        ]
        for error in needsTheUser { #expect(!StreamFailureCopy.isTransient(error), "\(error)") }
    }
}

struct ConnectFailureMappingTests {
    @Test func engineErrorsKeepWhichLegFailed() {
        func failure(_ error: Error) -> ConnectFailure? {
            if case .connectFailed(let failure) = NativeBackend.mapToStreamError(error) { return failure }
            return nil
        }
        #expect(failure(RtspError.connectTimeout(48010)) == .streamPortUnreachable(port: 48010))
        #expect(failure(RtspError.transportFailure("refused")) == .streamPortUnreachable(port: 0))
        #expect(failure(RtspError.noSdp) == .unsupported("no SDP"))
        #expect(failure(EnetError.connectTimeout) == .controlUnreachable)
        #expect(failure(EnetError.startFailed("START_A not ACKed")) == .hostWentQuiet)
        #expect(failure(EnetError.disconnected) == .hostWentQuiet)
        #expect(failure(EnetError.socketFailure("bind failed")) == .localSockets("bind failed"))
    }

    @Test func anInterruptedConnectIsACancellationNotAFailure() {
        for error in [RtspError.interrupted as Error, EnetError.interrupted] {
            guard case .cancelled = NativeBackend.mapToStreamError(error) else {
                Issue.record("\(error) must map to .cancelled")
                continue
            }
        }
        #expect(AppModel.isCancellation(StreamError.cancelled))
        #expect(AppModel.isCancellation(CancellationError()))
        #expect(!AppModel.isCancellation(StreamError.hostUnreachable("offline")))
    }

    @Test func aNameThatDoesNotResolveIsStillAReachFailure() {
        guard case .hostUnreachable =
                NativeBackend.mapToStreamError(EnetError.socketFailure("could not resolve host \"den.local\"")) else {
            Issue.record("an unresolvable name is the PC not being found")
            return
        }
    }
}

struct StopWhileStartingTests {
    /// /cancel quits the app Sunshine started. A connect that fails after the
    /// PC handed back a game that was already running must not send it - and
    /// a reconnect attempt, which is trying to get back to the game being
    /// played, never does.
    @Test func onlyAFreshLaunchIsUndone() {
        #expect(StreamSession.shouldCancelHostSession(resumed: false, duringReconnect: false))
        #expect(!StreamSession.shouldCancelHostSession(resumed: true, duringReconnect: false))
        #expect(!StreamSession.shouldCancelHostSession(resumed: false, duringReconnect: true))
        #expect(!StreamSession.shouldCancelHostSession(resumed: true, duringReconnect: true))
    }

    /// A stop that reaches the session before start() does (Cancel clicked in
    /// the same breath as Stream) used to be dropped at stop()'s guard; the
    /// stream then came up with nothing left that could end it.
    @Test func aSessionStoppedBeforeItStartsNeverStarts() async {
        let session = StreamSession()
        await session.stop()
        do {
            _ = try await session.start(
                server: ServerInfo(address: "192.0.2.1", uniqueId: "pc", serverName: "Den PC"),
                config: StreamConfig(width: 1280, height: 720, fps: 60, bitrateKbps: 10_000), appID: 1)
            Issue.record("start() ran after a stop")
        } catch {
            #expect(AppModel.isCancellation(error))
        }
        #expect(await session.stopRequested)
        #expect(await !session.startInProgress)
    }

    /// A stop that lands while start() is at its first network leg: start()
    /// throws `.cancelled` (not a reach failure for the launcher to show), and
    /// stop() returns only once start() has let go.
    @Test func aStopDuringTheFirstLegEndsInCancelled() async {
        let session = StreamSession()
        // TEST-NET-1: nothing answers, so start() sits in its /serverinfo leg.
        let starting = Task { () -> Error? in
            do {
                _ = try await session.start(
                    server: ServerInfo(address: "192.0.2.1", uniqueId: "pc", serverName: "Den PC"),
                    config: StreamConfig(width: 1280, height: 720, fps: 60, bitrateKbps: 10_000), appID: 1)
                return nil
            } catch { return error }
        }
        // Let start() get going, then stop it.
        for _ in 0..<200 {
            if await session.startInProgress { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await session.startInProgress)
        // As the app does it: cancel the start (its request aborts), and stop.
        starting.cancel()
        await session.stop()
        #expect(await !session.startInProgress)
        let error = await starting.value
        #expect(error.map(AppModel.isCancellation) == true, "start() threw \(String(describing: error))")
    }
}

struct PlayStationFailureTests {
    @Test func aConsoleThatNeverAnsweredDiscoveryIsUnreachableNotSilent() {
        let silent = StreamError.playStation(.noAnswer)
        guard case StreamError.playStation(.unreachable) =
                AppModel.playStationFailure(silent, answeredDiscovery: false) else {
            Issue.record("no discovery answer and no session is an unreachable console")
            return
        }
        guard case StreamError.playStation(.noAnswer) =
                AppModel.playStationFailure(silent, answeredDiscovery: true) else {
            Issue.record("a console that answered discovery is on but not answering Remote Play")
            return
        }
        // Other failures pass through untouched.
        guard case StreamError.playStation(.inUse) =
                AppModel.playStationFailure(StreamError.playStation(.inUse), answeredDiscovery: false) else {
            Issue.record("an in-use console answered")
            return
        }
    }

    @Test func quitReasonsMapToWhatTheUserCanDo() {
        #expect(PlayStationBackend.failure(for: CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_IN_USE) == .inUse)
        #expect(PlayStationBackend.failure(for: CHIAKI_QUIT_REASON_SESSION_REQUEST_REGIST_FAILED) == .registrationRejected)
        #expect(PlayStationBackend.failure(for: CHIAKI_QUIT_REASON_SESSION_REQUEST_INVALID_PSN_ID) == .accountNotRecognised)
        #expect(PlayStationBackend.failure(for: CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_CRASH) == .remotePlayCrashed)
        #expect(PlayStationBackend.failure(for: CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_VERSION_MISMATCH) == .versionMismatch)
        #expect(PlayStationBackend.failure(for: CHIAKI_QUIT_REASON_CTRL_CONNECT_FAILED) == .noAnswer)
        // Our own stop, and a session the console ended, are not failures to start.
        #expect(PlayStationBackend.failure(for: CHIAKI_QUIT_REASON_STOPPED) == nil)
        #expect(PlayStationBackend.failure(for: CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_SHUTDOWN) == nil)
        // A rejected registration is not retried as if the network had hiccuped.
        #expect(!PlayStationBackend.transientQuitReasons.contains(CHIAKI_QUIT_REASON_SESSION_REQUEST_REGIST_FAILED))
        #expect(!PlayStationBackend.transientQuitReasons.contains(CHIAKI_QUIT_REASON_SESSION_REQUEST_INVALID_PSN_ID))
    }

    @Test func playerOnesPadLeadsTheMerge() {
        // chiaki takes motion from the first pad that has any: player 1's.
        #expect(PlayStationBackend.mergeOrder(pads: [2, 0, 1], primary: 1) == [1, 0, 2])
        #expect(PlayStationBackend.mergeOrder(pads: [2, 0, 1], primary: nil) == [0, 1, 2])
        #expect(PlayStationBackend.mergeOrder(pads: [2, 1], primary: 0) == [1, 2])
        #expect(PlayStationBackend.mergeOrder(pads: [], primary: 0) == [])
    }

    @Test func aPadsOwnGoodbyeIsNotAttached() {
        #expect(PlayStationBackend.isAttached(1, activeMask: 0b11))
        #expect(!PlayStationBackend.isAttached(1, activeMask: 0b01))
        #expect(!PlayStationBackend.isAttached(0, activeMask: 0))
        #expect(PlayStationBackend.isAttached(PlayStationBackend.keyboardPadNumber, activeMask: 0))
    }

    @Test func restAtStreamEndIsReadWhenTheStreamEnds() {
        let defaults = UserDefaults(suiteName: "rest-at-end-\(UUID().uuidString)")!
        #expect(!PlayStationSettings.restsWhenStreamEnds(hostID: "ps5-aa", defaults: defaults))
        defaults.set(true, forKey: "PS5.ps5-aa.restWhenStreamEnds")
        #expect(PlayStationSettings.restsWhenStreamEnds(hostID: "ps5-aa", defaults: defaults))
        #expect(!PlayStationSettings.restsWhenStreamEnds(hostID: "ps5-bb", defaults: defaults))
    }
}

struct StreamFailureSurfaceTests {
    private static func host(_ id: String) -> Glimmer.Host {
        Glimmer.Host(id: id, name: id, customName: nil, localAddress: nil, manualAddress: nil,
                     apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil,
                     gfeVersion: nil, macAddress: nil)
    }

    /// The sentence shows on the page of the machine it is about, and only there.
    @Test @MainActor func aFailureBelongsToItsMachine() {
        let model = AppModel()
        let den = Self.host("den"), ps5 = Self.host("ps5-aa")
        model.selectedHost = ps5
        model.cleanupAfterStream(host: den, caughtError: StreamError.connectFailed(.controlUnreachable))
        #expect(model.streamFailure(for: den.id)?.contains("control connection") == true)
        #expect(model.streamFailure(for: ps5.id) == nil)
        // The selected machine is not blamed for another's failure.
        #expect(!model.streamErrorAffectsStatus(of: ps5.id))
        #expect(model.streamErrorAffectsStatus(of: den.id))
        // A firewall is the user's to fix: the menu bar says so.
        #expect(model.menuBarShowsStreamError)
        model.dismissStreamError()
        #expect(model.streamFailure(for: den.id) == nil)
    }

    /// Stopping a connect is not a failure, whichever way it was stopped.
    @Test @MainActor func aStoppedConnectLeavesNoFailure() {
        let model = AppModel()
        let den = Self.host("den")
        model.cleanupAfterStream(host: den, caughtError: StreamError.cancelled)
        #expect(model.nativeStreamError == nil)
        #expect(!model.menuBarShowsStreamError)
    }
}
