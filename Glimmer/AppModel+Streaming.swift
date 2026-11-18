//
//  AppModel+Streaming.swift
//
//  The streaming session lifecycle: the launch entry points (requestStream /
//  takeover confirm / stream(app:on:)), the single teardown cleanup, the
//  engine's StreamEvent handling, the connect cancel + connect-hold
//  adjudication, and the stream-ended toast copy. Split out of AppModel.swift
//  to keep each unit focused; the derived spec/hero-verb accessors and the
//  Host → engine config bridge live in AppModel+Streaming+Config.swift.
//

import Foundation
import AppKit
import AudioToolbox
import CoreAudio
import GameController
import SwiftUI
import Observation
import ServiceManagement
import os.log

extension AppModel {

    /// UI entry point for a launch. If the host is already streaming a
    /// DIFFERENT app, arm `pendingTakeover` for a confirm before we quit it;
    /// otherwise stream straight through.
    ///
    /// Asking for the app that is already running is not a takeover, it's a
    /// resume: the host keeps the session and hands it to us (`currentgame ==
    /// our appID → /resume`, see StreamSession+Start). Nothing is lost, so
    /// there is nothing to confirm - the dialog there was pure friction on the
    /// commonest path there is, reconnecting to your own session after the
    /// stream window closed.
    ///
    /// The one case this lets through quietly is another device streaming the
    /// same app: resuming takes it from them. nvhttp gives us no way to tell
    /// that apart from our own orphaned session - both are just `currentgame`
    /// - and every Moonlight client resumes on a name match too.
    func requestStream(app: LibraryApp, on host: Host) {
        guard !isStreaming else { stream(app: app, on: host); return }  // stream() logs + ignores
        // A PS5 has no GameStream session to take over; it may need waking.
        if host.isPlayStation { requestPlayStationStream(on: host); return }
        if let live = hostLiveStatus, live.hostID == host.id,
           live.state.hasSessionInformation,
           Date().timeIntervalSince(live.capturedAt) <= HostLiveStatus.stale {
            let occupant: String?
            switch live.state {
            case .streamingApp(let name): occupant = name
            case .streamingUnknownApp: occupant = Self.unknownOccupantName
            default: occupant = nil
            }
            if Self.isTakeover(occupant: occupant, launching: app.name) {
                askToTakeOver(PendingTakeover(app: app, host: host, occupantApp: occupant ?? ""))
                return
            }
            stream(app: app, on: host)
            return
        }
        // No fresh snapshot - the first seconds after launch, or the poller
        // paused. Deciding from nothing streamed straight through, and the
        // session's own launch plan then /cancel'd whatever the host was
        // running (measured: a test launch from a second Mac ended a game
        // being played from the first). Ask the host now; it is one
        // /serverinfo, well under the connect time.
        // One check at a time: during it the menu offers End Stream, not
        // Stream, but a second click can land before the menu is rebuilt.
        guard streamCheckHostID == nil else {
            Diag.notice("Ignoring stream request - still asking \(host.displayName, privacy: .private) what it runs", "Stream")
            return
        }
        let info = nativeServerInfo(for: host)
        let token = UUID()
        streamCheckHostID = host.id
        streamCheckToken = token
        streamCheckTask = Task { [weak self] in
            // Cleared after stream() has set the connecting phase, so the
            // spinner runs on without a gap. A cancelled check was cleared
            // by cancelStreamCheck() already (and may have a successor).
            defer {
                if let self, self.streamCheckToken == token {
                    self.streamCheckHostID = nil
                    self.streamCheckToken = nil
                    self.streamCheckTask = nil
                }
            }
            let client = NetworkClient(server: info)
            let fresh = try? await client.fetchServerInfo()
            await client.shutdown()
            guard let self, !Task.isCancelled, self.streamCheckToken == token else { return }
            guard !self.isStreaming, self.pendingTakeover == nil else { return }
            guard let fresh else {
                // Unreachable: let the session report that in its own words.
                self.stream(app: app, on: host)
                return
            }
            let occupant = Self.occupantName(currentGameID: fresh.currentGameID, apps: host.apps)
            if Self.isTakeover(occupant: occupant, launching: app.name) {
                Diag.notice("Takeover check: \(host.displayName, privacy: .private) is running \(occupant ?? "?") - asking before launching \(app.name)", "Stream")
                self.askToTakeOver(PendingTakeover(app: app, host: host, occupantApp: occupant ?? ""))
                return
            }
            self.stream(app: app, on: host)
        }
    }

    /// Ask before starting an app over the one the PC is running. The main
    /// window shows the question as its own dialog; with no window open -
    /// Stream from the menu bar, a Switch PC, the usual way in now that
    /// Shimmer lives there - there was nowhere for it to appear: the click
    /// did nothing, later clicks were dropped while the question stood, and
    /// the dialog popped up whenever the window was next opened. Then it is
    /// an alert of its own.
    func askToTakeOver(_ pending: PendingTakeover) {
        pendingTakeover = pending
        guard !Self.mainWindowIsVisible else { return }
        // Next turn: this can be reached from inside the menu's own tracking.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingTakeover == pending, !Self.mainWindowIsVisible else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Take over the stream?"
            alert.informativeText = Self.takeoverQuestion(pending)
            alert.addButton(withTitle: "Take Over").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            let answer = alert.runModal()
            // The window may have opened and answered meanwhile.
            guard self.pendingTakeover == pending else { return }
            if answer == .alertFirstButtonReturn {
                self.confirmPendingTakeover()
            } else {
                self.pendingTakeover = nil
            }
        }
    }

    /// Both apps get named: this only comes up when they DIFFER (asking for
    /// the running app resumes it instead - see requestStream), so "what am
    /// I losing, and for what" is the whole question being asked.
    nonisolated static func takeoverQuestion(_ pending: PendingTakeover) -> String {
        "\(pending.host.displayName) is already streaming \(pending.occupantApp). "
            + "Starting \(pending.app.name) will quit it and end that session."
    }

    static var mainWindowIsVisible: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isVisible }
    }

    /// What the takeover dialog calls an app the host reports by an id we
    /// have no name for (a stale app list).
    nonisolated static let unknownOccupantName = "another app"

    /// The host's running app by name, from its /serverinfo `currentgame`:
    /// nil when idle, the library name when known, `unknownOccupantName`
    /// when the id is not in the stored list (still someone's session).
    nonisolated static func occupantName(currentGameID: Int, apps: [LibraryApp]) -> String? {
        guard currentGameID != 0 else { return nil }
        return apps.first(where: { $0.id == currentGameID })?.name ?? unknownOccupantName
    }

    /// Does starting `appName` cost the host's current session? Only when some
    /// OTHER app holds it - the same app is a resume. Pure so the distinction
    /// is checkable without a host or a live status.
    nonisolated static func isTakeover(occupant: String?, launching appName: String) -> Bool {
        guard let occupant, !occupant.isEmpty else { return false }
        return occupant != appName
    }

    /// Confirm the armed takeover and launch over the host's current session.
    func confirmPendingTakeover() {
        guard let pending = pendingTakeover else { return }
        pendingTakeover = nil
        stream(app: pending.app, on: pending.host)
    }

    func stream(app: LibraryApp, on host: Host) {
        // RE-ENTRANCY GUARD. The native backend runs ONE session at a time
        // (StreamBridgeContext.current is a single process-global slot), and
        // a second entry here would corrupt it wholesale: a second
        // StreamSession overwrites nativeSession, markStreamStart() wipes the
        // live session's pending receipt, the new launch's /cancel kills the
        // old host-side session, and the old session's teardown then clobbers
        // isStreaming/streamPhase out from under the new one. The UI disables
        // its launch surfaces while a session exists, but a double-click can
        // land before SwiftUI re-renders - this guard is the actual wall.
        guard !isStreaming else {
            Diag.notice("Ignoring stream request (\(app.name) on \(host.displayName, privacy: .private)) - a session is already in flight", "Stream")
            return
        }
        Diag.notice("Starting stream → \(host.displayName, privacy: .private) · \(app.name)", "Stream")
        selectForStream(host)
        streamPhase = .connecting(stage: "Connecting to \(host.displayName)…")
        nativeStreamError = nil
        nativeHDRActive = false
        activeStreamWidth = 0; activeStreamHeight = 0; activeStreamFps = 0
        // Re-arm the disconnect toast for back-to-back cycles: if the
        // previous session's toast is still inside its 2-4 s hold, dropping
        // the flag here unmounts it (cancelling its hold task) so the NEXT
        // stream end mounts a fresh toast with a full hold, instead of the
        // new toast inheriting the old one's residual timer.
        streamEndedToastVisible = false
        // Connect-hold adjudication breadcrumb, half one: anchor the span at
        // the CLICK (the engine's own clock starts after HTTPS + window
        // build, so it can't answer "did the user wait >400 ms"). The live
        // edge in handleNativeEvent logs the verdict.
        Self.connectClickedAt = Date()
        // True click-to-pixels anchor (telemetry): clear any prior session's
        // latch, then anchor at this launch click - before the connect Task spins
        // up - the leg handshake_total_ms (connect-start anchored) can't see.
        // Resolved at the .firstFrame edge. Reset HERE (not in
        // TelemetryCounters.resetForNewSession, which runs AFTER the click).
        ConnectTimingTelemetry.shared.resetForNewSession()
        ConnectTimingTelemetry.shared.anchorClick()
        Self.connectCapsuleShown = false
        Self.connectCancelRequested = false
        activeStreamApp = app
        activeStreamHostID = host.id
        activeStreamHasVideo = false
        isStreaming = true
        // Cancel the chip poller while the stream is up - the native
        // engine reports its own RTT to the stats overlay, and polling
        // /serverinfo concurrently with the RTSP handshake confuses both
        // Sunshine's logs and our own latency story.
        hostStatusTask?.cancel()
        hostStatusTask = nil
        hostLiveStatus = nil

        let cfg = sessionStreamConfig(for: host, app: app)
        let info = nativeServerInfo(for: host)
        // Hero-verb memory: stamp the app NAME at stream START (unlike the
        // lastConnected DATE above) so the next launcher visit names the app in
        // "Stream <app>" even if this session ends badly.
        UserDefaults.standard.set(app.name, forKey: Self.lastPlayedAppKey(for: host.id))
        // Arm the session-receipt latch with this session's identity (host +
        // requested mode). The live edge stamps the wall clock; the teardown
        // hook in StreamSession.stop() adds the end-of-session numbers; the
        // cleanup below finalizes. See SessionReceiptStore for the contract.
        SessionReceiptStore.markStreamStart(
            hostId: host.id, width: cfg.width, height: cfg.height, refreshHz: cfg.fps)
        let token = UUID()
        currentStreamToken = token
        launchSession(app: app, host: host, cfg: cfg, info: info, token: token)
    }

    /// The StreamConfig for a stream of `app` on `host` (a PS5 sends a fixed
    /// preset; the window, pacer, receipt and stats are sized for that).
    func sessionStreamConfig(for host: Host, app: LibraryApp) -> StreamConfig {
        var cfg = nativeStreamConfig(for: host)
        if host.isPlayStation {
            // The console sends a fixed preset (1080p/720p at 60/30, SDR); size
            // the window, pacer, receipt and stats for that, not for the
            // Sunshine settings.
            let ps = playStationStreamOptions(for: host)
            cfg.width = Int(ps.width)
            cfg.height = Int(ps.height)
            cfg.fps = ps.fps
            cfg.hdr = false
            cfg.bitrateKbps = ps.bitrateKbps ?? (ps.resolution == .p1080 ? 15_000 : 10_000)
        }
        cfg.windowTitle = Self.streamWindowTitle(hostName: host.displayName, appName: app.name)
        // One line naming how the stream will be shown and what was asked for,
        // so a "why is it 1080p in a window" report answers itself from the log.
        Diag.info("Stream \(StreamFullScreenMemory.opensFullScreen() ? "opens full screen" : "opens in a window") - requesting "
            + "\(cfg.width)x\(cfg.height) at \(cfg.fps) Hz", "Stream")
        return cfg
    }

    /// Start a StreamSession and run it to its end. `token` is the stream's
    /// identity: AppModel's live state follows only the CURRENT stream
    /// (`currentStreamToken`), so one that a switch ended, still closing,
    /// can't touch it. Every callback and event checks it.
    func launchSession(app: LibraryApp, host: Host, cfg: StreamConfig, info: ServerInfo, token: UUID) {
        // Hotkey chords are read live via providers (see below) rather
        // than captured here, so edits to quitHotkey/statsHotkey in
        // Settings take effect mid-stream without restarting.
        //
        // Seed the session-scoped stats-overlay state from the user's
        // persisted preference. The in-stream hotkey toggles this value
        // but intentionally does not write back to UserDefaults - see the
        // doc on `statsHotkey`.
        let initialStatsOverlay = showStreamStats

        Task { [weak self] in
            guard let self else { return }
            var caughtError: Error?
            // A PS5 that never answered discovery (see readyPlayStation).
            var answeredDiscovery = true
            do {
                if host.isPlayStation {
                    // Find and wake the console first: part of this attempt,
                    // so Cancel, End Stream and a switch all stop it.
                    let preflight = Task { try await self.readyPlayStation(host, token: token) }
                    self.streamPreflightTask = preflight
                    defer { self.streamPreflightTask = nil }
                    answeredDiscovery = try await preflight.value
                }
                // The backend is built after that step: it takes the
                // console's address, which the step may have just corrected.
                let backend = self.makeStreamingBackend(for: host)
                let session = StreamSession(backend: backend)
                self.nativeSession = session
                // The audio cushion ceiling, before the engine seeds the cushion.
                session.audioDecoder.setCushionCeiling(
                    self.preferLowAudioLatency ? AudioDecoder.lowLatencyCushionCeilingMs : nil)
                // Seed the persisted stream volume / mute BEFORE the first
                // packet decodes, so a stream the user left muted comes up
                // muted instead of blasting for the half-second it takes them
                // to reach the menu bar. The decoder just stores it here (its
                // engine doesn't exist yet) and applies it when it builds the
                // graph - see AudioDecoder.outputVolume.
                self.applyStreamVolume()
                // Provider closures (rather than captured values) so the user
                // can edit either hotkey in Settings while a stream is live
                // and the change takes effect on the next keyDown - no need
                // to restart the stream to see a new chord work. `self` is
                // captured weakly to avoid a cycle with the session.
                // start() runs as its own task so a stop can cancel it: the
                // control requests abort on cancellation, where a stop alone
                // had to wait out a socket timeout against a PC that is off.
                let starting = Task { try await session.start(
                    server: info, config: cfg, appID: app.id,
                    quitHotkeyProvider: { [weak self] in self?.quitHotkey ?? .defaultQuit },
                    statsHotkeyProvider: { [weak self] in self?.statsHotkey ?? .defaultStats },
                    // Telemetry-bookmark chord (signal 4). Fixed default ⌃B for
                    // now - client-only, consumed in the input path, never
                    // forwarded to the host. (Made user-configurable later if
                    // desired, alongside quit/stats in Settings.)
                    bookmarkHotkeyProvider: { .defaultBookmark },
                    releasePointerHotkeyProvider: { [weak self] in
                        self?.releasePointerHotkey ?? .defaultReleasePointer
                    },
                    initialStatsOverlay: initialStatsOverlay,
                    initialStatsCorner: streamStatsCorner,
                    // Provider closure so a Settings preset/checkbox
                    // change during a live stream takes effect on the
                    // next 1Hz overlay tick. Resolves through
                    // `effectiveStatsRows` (preset → curated set, or
                    // custom → user toggles); the weak-self collapse to
                    // the Extended default is a defensive fallback.
                    statsRowsProvider: { [weak self] in
                        self?.effectiveStatsRows ?? StatsOverlayDefaults.extendedRows
                    },
                    statsThresholdsProvider: { [weak self] in
                        self?.statsThresholds ?? .default
                    },
                    onBackgroundedChanged: { [weak self] backgrounded in
                        guard self?.currentStreamToken == token else { return }
                        self?.nativeStreamBackgrounded = backgrounded
                    },
                    pipHotkeyProvider: { [weak self] in self?.pipHotkey ?? .defaultPiP },
                    startInPictureInPictureProvider: { [weak self] in
                        self?.consumePictureInPictureLaunch() ?? false
                    },
                    keepAwakeProvider: { [weak self] in self?.keepAwakePolicy ?? .always },
                    quitAppOnStopProvider: { [weak self] in
                        self?.streamSettings(for: host.id).quitAppWhenStreamEnds ?? false
                    },
                    onPictureInPictureChanged: { [weak self] active in
                        guard self?.currentStreamToken == token else { return }
                        self?.nativeStreamPictureInPicture = active
                    },
                    pipPointerProvider: { true },
                    reconnectAddresses: Self.candidateAddresses(for: host)
                ) }
                self.streamStartTask = starting
                defer { self.streamStartTask = nil }
                let events = try await starting.value
                self.streamStartTask = nil
                for await event in events {
                    // Pass the SESSION's host, not selectedHost: ⌘1-⌘9 / the
                    // toolbar pill can re-select mid-flight, and failure copy
                    // resolved at event time would then blame the wrong PC.
                    await MainActor.run { self.route(event, host: host, token: token) }
                }
            } catch {
                caughtError = host.isPlayStation
                    ? Self.playStationFailure(error, answeredDiscovery: answeredDiscovery) : error
            }
            // Single cleanup site: runs whether start() threw or the event
            // loop drained normally.
            self.finishSession(host: host, caughtError: caughtError, token: token)
        }
    }

    /// The single teardown cleanup for stream(app:on:). Main-actor by class
    /// isolation; named so the entry path stays readable and the cleanup
    /// stays one site - never duplicate any of this elsewhere (a second
    /// "cleanup" is how zombie state is made).
    func cleanupAfterStream(host: Host, caughtError: Error?) {
        AWDLGuard.shared.streamEnded()
        GameModeBoost.shared.streamLive(false, enabled: gameModeDuringStreams)
        if let caughtError, Self.connectCancelRequested || Self.isCancellation(caughtError) {
            // The stream was stopped while it was still connecting - Cancel,
            // End Stream, the quit shortcut, closing the window, a switch to
            // another machine. start()'s throw is that stop ARRIVING, not a
            // failure to report: a "couldn't reach" banner here would
            // contradict a deliberate, successful stop.
            self.log.info("Connect stopped on request - no failure to report")
            self.nativeStreamError = nil
        } else if let caughtError {
            let hostName = host.displayName
            // One human sentence - never splice the raw NSError tail
            // ("The request timed out", domain codes, ...) into the
            // banner. The technical detail goes to the log; the user
            // gets an actionable line. StreamError already carries
            // user-facing copy and is handled on its own path.
            let localized = (caughtError as NSError).localizedDescription
            self.log.error("Stream start failed for \(hostName, privacy: .private): \(localized, privacy: .private)")
            // Diag too - the os.Logger line above never reaches the in-app
            // log viewer or the Diag file, which made pre-flight failures
            // (the only line naming the real cause) invisible in every
            // pasted log. One line, ERROR level, same redaction rules.
            Diag.error("Stream start failed for \(hostName, privacy: .private): \(localized, privacy: .private)", "Stream")
            // HONEST banner: only show the "make sure it's awake" copy
            // for a GENUINE reach failure (host off / not on the
            // network). A pairing or launch failure means the host
            // demonstrably answered - telling the user it's "asleep"
            // there is a false negative that sends them chasing the
            // wrong problem. Reserve the asleep guidance for the
            // unreachable / never-established cases; surface the real
            // cause otherwise. (This is the start()-throw path only:
            // start() throwing means the connection never reached
            // established and no frames ever decoded, so the
            // reach-failure copy is correct there.)
            self.nativeStreamError =
                Self.connectFailureBanner(for: caughtError, hostName: hostName)
            self.streamErrorHostID = host.id
            if Self.isTransientConnectionFailure(caughtError) {
                markStreamInterruption(hostID: host.id)
            }
        }
        // M3: do NOT unconditionally clear nativeStreamError here. A host-side
        // "ended unexpectedly" terminate (code != 0) already set the banner on
        // the event loop, and this single teardown runs for BOTH a clean quit
        // and that host error - unconditionally nilling wiped the banner before
        // it ever rendered (host crash / power-loss / watchdog stall looked
        // identical to a clean quit, and Retry went dead). Leaving an already-set
        // banner in place lets it survive; a clean quit set it to nil up above
        // (line 273 at stream start) so nothing stale leaks through.
        let wasStreaming = self.isStreaming
        // A "Stream in Picture in Picture" that never got as far as a window
        // must not ride along with the next plain Stream click (it did, for
        // up to a minute after a failed start).
        self.pictureInPictureLaunchRequestedAt = nil
        // Switching PCs: this stream ended so the next can start - quietly,
        // with no "stream over" in between.
        let switching = pendingHostSwitch != nil
        if !switching { StreamWindow.switchingHosts = false }
        self.recordStreamActivity(for: host.id)
        self.activeStreamHostID = nil
        self.activeStreamHasVideo = false
        self.streamPhase = .idle
        self.isStreaming = false
        self.activeStreamApp = nil
        self.nativeStreamBackgrounded = false
        self.nativeStreamPictureInPicture = false
        self.nativeSession = nil
        // Disconnect beat (#3) - surface the "Stream ended" toast on
        // the launcher only when we actually had a live session.
        // Skipping the toast on the connection-failure path (where
        // wasStreaming is true but the user already sees a
        // ConnectBanner error explaining what happened) would lose
        // the acknowledgement; the toast is intentionally redundant
        // with the banner because the banner reads as "still trying"
        // and the toast reads as "we're done here".
        if wasStreaming, !switching {
            // Build + stash the session receipt BEFORE the toast flag
            // flips so the toast's first render already carries its
            // quiet line. nil for short (<5 min) sessions and dead
            // connects - the toast stays a single line for those.
            self.lastSessionReceipt = SessionReceiptStore.finalizeSession()
            // One INFO either way - in testing the receipt write was
            // log-silent (stash vs skip was indistinguishable in any
            // artifact), so adjudicating the ≥5-min gate took a
            // UserDefaults spelunk. One grep now.
            if let receipt = self.lastSessionReceipt {
                Diag.info("Session receipt stashed - \(receipt.summaryLine) · "
                    + "\(receipt.width)x\(receipt.height)@\(receipt.refreshHz)", "Stream")
            } else {
                Diag.info("Session receipt skipped - never went live or under the "
                    + "5-minute stash threshold", "Stream")
            }
            self.streamEndedToastVisible = true
        }
        // Re-arm the readiness-chip poller so it goes back to
        // "Ready · 12 ms" instead of holding its last value from
        // the moment polling stopped at stream start. `afterStream:
        // true` adds a short settle delay before the first probe so it
        // doesn't race the host's `/cancel`-induced HTTP blip and
        // publish a false "Asleep" on a host that was streaming moments
        // ago (the chip slander bug). Combined with the two-strikes
        // unreachable guard in the poller, an awake host that just
        // streamed can never be declared asleep on a single transient
        // miss.
        self.restartHostStatusPolling(afterStream: true)
        // Switching PCs: the next stream starts now, in the same mode - no
        // focus steal, no main window in between.
        if let next = pendingHostSwitch {
            pendingHostSwitch = nil
            switchWakeTask?.cancel()
            switchWakeTask = nil
            startPendingHostSwitch(next)
            return
        }
        // No launcher hand-off: Shimmer lives in the menu bar, and bringing
        // its window up (with an activation) dragged the user to whichever
        // Space it was on. A failure shows in the menu bar (and in the main
        // window, if it is open).
    }

    /// start() throws `.cancelled` when a stop reached it before the stream
    /// was up (StreamSession.stopRequested).
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if case StreamError.cancelled = error { return true }
        return error is CancellationError
    }

    /// Network interruptions never raise the menu-bar triangle; failures that
    /// need the user (pairing, certificates, a firewall, the decoder) do.
    nonisolated static func isTransientConnectionFailure(_ error: Error) -> Bool {
        StreamFailureCopy.isTransient(error)
    }

    /// The sentence for a stream that never started (StreamFailureCopy).
    nonisolated static func connectFailureBanner(for error: Error, hostName: String) -> String {
        StreamFailureCopy.connect(error, hostName: hostName)
    }

    /// Handle one engine event for the session streaming `host`. The host is
    /// the SESSION's host captured at stream() entry - never `selectedHost`,
    /// which the ⌘1-⌘9 shortcuts and the toolbar pill can re-point mid-flight
    /// (failure copy resolved at event time then names the wrong machine).
    func handleNativeEvent(_ event: StreamEvent, host: Host) {
        // Stage names are engineering jargon ("Starting RTSP handshake"). Keep
        // them in logs but show the user a friendly "Connecting to <host>..."
        // through the whole handshake.
        let connecting = "Connecting to \(host.displayName)…"
        switch event {
        case .stageStarting:
            // Don't let a late stage event repaint "Connecting…" over the
            // "Cancelling…" the user's cancel click just earned.
            if !Self.connectCancelRequested { streamPhase = .connecting(stage: connecting) }
        case .stageComplete:              break
        case .stageFailed:
            nativeStreamError = "Couldn't reach \(host.displayName)."
            streamErrorHostID = host.id
            markStreamInterruption(hostID: host.id)
        case .connectionEstablished:
            nativeStreamError = nil
            streamPhase = .streaming
            logConnectHoldAdjudication()
            // Receipt wall-clock starts at the LIVE edge (not the click) so
            // "2h 12m" measures time actually streaming, not handshake.
            // Latched once inside the store - repeat edges are no-ops.
            SessionReceiptStore.markSessionLive()
            noteStreamLiveForAWDL()
        case .firstFrame:
            markStreamVideo(for: host.id)
            promoteToStreamingOnFirstFrame()
        case .connectionTerminated(let code):
            streamPhase = .idle
            nativeHDRActive = false
            activeStreamWidth = 0; activeStreamHeight = 0; activeStreamFps = 0
            if code != 0 {
                nativeStreamError = "Stream to \(host.displayName) ended unexpectedly."
                if code == StreamSession.deadPeerTerminationCode {
                    nativeStreamError = "Connection to \(host.displayName) was interrupted. Stream again to resume."
                }
                streamErrorHostID = host.id
                markStreamInterruption(hostID: host.id)
            }
        case .reconnecting:
            // The host closed a live session (it likely restarted across a
            // lock/desktop transition) and the engine is silently re-establishing
            // under the frozen last frame. Show "Reconnecting..." - DON'T go .idle,
            // which would tear the hero card back to the launcher; the stream
            // window stays up holding the frame. Resolves on .reconnected or, if
            // the engine gives up, a real .connectionTerminated.
            streamPhase = .connecting(stage: "Reconnecting to \(host.displayName)…")
        case .reconnected:
            nativeStreamError = nil
            // Resumed in place. (The fresh .connectionEstablished / .firstFrame
            // edges also promote the phase, so this is belt-and-braces.)
            streamPhase = .streaming
        case .connectionStatus(let quality):
            // .good / .degraded both leave us in the streaming phase -
            // the stats overlay carries the real-time network signal,
            // and there's no other user-visible surface for "network is
            // slow" copy that distinguishing them would feed.
            _ = quality
            streamPhase = .streaming
        case .hdrModeChanged: break  // intent signal only - see .hdrActive
        case .hdrActive(let active): nativeHDRActive = active
        case let .streamFormat(width, height, fps, _):
            // Codec rides the event but is not currently surfaced; the header
            // shorthand uses size + refresh + HDR.
            activeStreamWidth = width; activeStreamHeight = height; activeStreamFps = fps
        case .audioFailed:
            // H7: audio receive failed to start - the session is video-only.
            // Non-fatal to the visual stream, so stay in the streaming phase;
            // the failure is already logged + counted at the source.
            break
        case .log: break
        }
    }

    /// Ground-truth liveness: a decoded/rendered frame proves the stream is up
    /// regardless of whether the one-shot .connectionEstablished edge was
    /// delivered. Promote ONLY out of a connecting phase - never override a
    /// teardown that has already moved us to .idle/.error (a late first-frame
    /// yield racing stop() must not resurrect the streaming phase). This is the
    /// belt-and-suspenders fix for "stuck on Connecting while video is actually
    /// flowing": if .connectionEstablished was lost, the first frame repairs the
    /// transition within ~one frame.
    /// The stream is live: park AWDL if the user asked and the route is Wi-Fi
    /// (idempotent - both live edges call it).
    func noteStreamLiveForAWDL() {
        guard let host = hosts.first(where: { $0.id == activeStreamHostID }) else { return }
        AWDLGuard.shared.streamStarted(hostAddress: dialAddress(for: host))
        GameModeBoost.shared.streamLive(true, enabled: gameModeDuringStreams)
    }

    private func promoteToStreamingOnFirstFrame() {
        guard case .connecting = streamPhase else { return }
        nativeStreamError = nil
        streamPhase = .streaming
        logConnectHoldAdjudication()
        // Same live-edge stamp as .connectionEstablished - whichever edge
        // arrives first starts the receipt clock (store-latched).
        SessionReceiptStore.markSessionLive()
            noteStreamLiveForAWDL()
    }

    // MARK: - Connect cancel + connect-hold adjudication

    // Static (type-level) storage: extensions can't add instance properties,
    // and these are single-session scratch by construction - the re-entrancy
    // guard in stream() means at most one connect is ever in flight. All
    // three inherit the class's @MainActor isolation.

    /// Wall clock of the most recent stream() entry (the user's CLICK). The
    /// engine's own clock starts after HTTPS + window build, so only this
    /// anchor can adjudicate the 400 ms connect hold. Consumed (nil'd) by
    /// `logConnectHoldAdjudication()` so the verdict logs exactly once.
    private static var connectClickedAt: Date?

    /// Whether the 400 ms-held connecting capsule actually mounted for the
    /// in-flight connect. Ground truth reported by ConnectSurface at the flip
    /// - not inferred from the span, which would assume the launcher was
    /// frontmost and the hold task uncancelled.
    private static var connectCapsuleShown = false

    /// True once the user cancelled the in-flight connect. Read by the
    /// teardown cleanup to suppress the failure banner (a deliberate cancel
    /// is not a failure) and by `.stageStarting` to keep a late stage event
    /// from repainting over "Cancelling…". Reset at every stream() entry.
    private static var connectCancelRequested = false

    /// ConnectSurface calls this when its 400 ms hold elapses and the
    /// connecting capsule mounts - the "shown" half of the adjudication line.
    func noteConnectCapsuleShown() {
        Self.connectCapsuleShown = true
    }

    /// End the live stream without quitting Shimmer - the menu bar's "End
    /// Stream" row. Routes through the session's own teardown exactly like
    /// the quit hotkey does, so there is still one cleanup site; whether the
    /// game is also quit on the PC follows Settings › "Quit the game on the
    /// PC", the same as any other way of ending a stream.
    /// The menu bar's "Switch PC": select it, and if a stream is running on
    /// another PC, end that one and start this one's default app in the same
    /// presentation - straight into Picture in Picture if that is where the
    /// stream was. (Selecting alone left the old stream running.)
    func switchHost(to host: Host) {
        let streamingElsewhere = isStreaming && activeStreamHostID != host.id
        let inPictureInPicture = nativeStreamPictureInPicture
        selectHost(host)
        // The old stream is already closing for a switch: it can't be kept,
        // but where the next one opens still can change. The last pick wins -
        // back to the machine that was playing included (it reopens there).
        // Ignored, this ended the stream and started nothing.
        if StreamWindow.switchingHosts, pendingHostSwitch != nil {
            pendingHostSwitch?.hostID = host.id
            return
        }
        // Back to the PC already playing: drop a switch still connecting.
        if isStreaming, activeStreamHostID == host.id {
            switchWakeTask?.cancel()
            switchWakeTask = nil
            pendingHostSwitch = nil
            return
        }
        guard streamingElsewhere else { return }
        switchWakeTask?.cancel()
        switchWakeTask = nil
        // Never in place: this stream closes - its Picture in Picture window
        // or its stream window - and the next opens the same way, fresh
        // (startPendingHostSwitch). The menu bar spins until it's up.
        pendingHostSwitch = PendingHostSwitch(hostID: host.id, inPictureInPicture: inPictureInPicture,
                                              requestedAt: Date())
        let begin: @MainActor () -> Void = { [weak self] in self?.beginHostSwitch() }
        guard host.isPlayStation else {
            begin()
            return
        }
        // A PS5 in rest mode takes ~15 s to wake: wake it while the current
        // game keeps playing, and connect once it answers.
        Diag.notice("Switching the stream to \(host.displayName, privacy: .private) - waking it first", "Stream")
        switchWakeTask = Task { [weak self] in
            let ready = await self?.wakePlayStationForSwitch(host) ?? false
            guard let self, !Task.isCancelled, self.pendingHostSwitch?.hostID == host.id, self.isStreaming,
                  self.activeStreamHostID != host.id, !StreamWindow.switchingHosts else { return }
            self.switchWakeTask = nil
            guard ready else {
                // The console never came up: the game that is playing keeps
                // playing. Closing it for a stream that can't start left the
                // user with neither.
                self.pendingHostSwitch = nil
                self.nativeStreamError = StreamFailureCopy.playStation(.didNotWake, hostName: host.displayName)
                self.streamErrorHostID = host.id
                self.markStreamInterruption(hostID: host.id)
                Diag.error("Switch to \(host.displayName, privacy: .private) dropped - it didn't wake; "
                    + "the current stream stays", "Stream")
                return
            }
            begin()
        }
    }

    /// Wake a PS5 that isn't ready, waiting until it answers (up to 40 s).
    /// False when it still isn't ready at the end of the wait.
    private func wakePlayStationForSwitch(_ host: Host) async -> Bool {
        guard let console = playStationConsole(for: host) else { return false }
        let status = await PlayStationDiscovery.probe(address: console.address)
        if status?.power == .ready { return true }
        guard !Task.isCancelled else { return false }
        Diag.notice("PS5: waking \(console.nickname) before switching to it", "PlayStation")
        return await PlayStationDiscovery.wakeAndWait(console: console, timeout: Self.playStationWakeSeconds)
    }

    /// End the current stream for the pending switch: its PiP window or
    /// stream window closes, and the next stream reopens it the same way.
    private func beginHostSwitch() {
        guard var next = pendingHostSwitch, isStreaming else { return }
        next.inPictureInPicture = nativeStreamPictureInPicture
        // The switch's 30 s start now, not at the click: a PS5 that took
        // most of them to wake had its stream dropped as "too late".
        next.requestedAt = Date()
        pendingHostSwitch = next
        Diag.notice("Switching the stream now - closing this one, then opening the next"
            + (next.inPictureInPicture ? " in Picture in Picture" : ""), "Stream")
        StreamWindow.switchingHosts = true
        endStream()
    }

    func startPendingHostSwitch(_ next: PendingHostSwitch) {
        StreamWindow.switchingHosts = false
        guard Date().timeIntervalSince(next.requestedAt) < Self.hostSwitchWindowSeconds,
              let target = hosts.first(where: { $0.id == next.hostID }) ?? selectedHost.flatMap({
                  $0.id == next.hostID ? $0 : nil }) else {
            nativeStreamBackgrounded = false
            nativeStreamPictureInPicture = false
            return
        }
        // The switch goes where it was asked to go: looking at another
        // machine's page while the old stream closed is not a change of mind
        // (that is another Switch PC, which re-targets the pending switch).
        if selectedHost?.id != target.id { selectHost(target) }
        if next.inPictureInPicture {
            pictureInPictureLaunchRequestedAt = Date()
        } else {
            // The click that asked is long gone: come forward without it.
            StreamWindow.forceActivate()
        }
        streamDefaultApp()
    }

    nonisolated static let hostSwitchWindowSeconds: TimeInterval = 30

    func endStream() {
        // Ending the stream yourself while a switch is still waking its PS5
        // ends it for good - the switch is dropped.
        if !StreamWindow.switchingHosts {
            switchWakeTask?.cancel()
            switchWakeTask = nil
            pendingHostSwitch = nil
        }
        if cancelStreamCheck() { return }
        guard isStreaming else { return }
        Diag.notice("User ended the stream from the menu bar", "Stream")
        // Ended on purpose: if the stream was still connecting, its start()
        // throwing is this stop arriving, not a failure to show.
        Self.connectCancelRequested = true
        // Still finding or waking a PS5: there is no session yet, only that step.
        streamPreflightTask?.cancel()
        streamStartTask?.cancel()
        guard let session = nativeSession else { return }
        // In Picture in Picture: close the PiP first, as its × does, while
        // the stream still feeds it - closed after, its closing animation
        // draws an empty (black) picture.
        Task {
            await session.closePictureInPicture()
            await session.stop()
        }
    }

    /// (and its ⎋ shortcut). Routes through the SESSION's own teardown so
    /// there is exactly ONE cleanup site: stop() interrupts the handshake,
    /// start() returns or throws, and the single cleanup in stream()'s Task
    /// drains state back to idle. We only repaint the visible stage here -
    /// never isStreaming/streamPhase-to-idle directly - because faking the
    /// end state from a second site is how zombie sessions are made.
    func cancelConnect() {
        if cancelStreamCheck() { return }
        guard isStreaming, case .connecting = streamPhase else { return }
        guard !Self.connectCancelRequested else { return }  // one stop() is plenty (it's idempotent anyway)
        Self.connectCancelRequested = true
        Diag.notice("User cancelled connect - stopping the in-flight session", "Stream")
        streamPhase = .connecting(stage: Self.cancellingStage)
        // Still finding or waking a PS5: there is no session yet, only that step.
        streamPreflightTask?.cancel()
        streamStartTask?.cancel()
        if let session = nativeSession { Task { await session.stop() } }
    }

    nonisolated static let cancellingStage = "Cancelling…"

    /// Stop a stream that is still at its first step - asking the PC what it
    /// runs (requestStream) - before any session exists: nothing starts.
    /// Returns whether there was one to stop.
    @discardableResult
    func cancelStreamCheck() -> Bool {
        guard streamCheckHostID != nil else { return false }
        Diag.notice("User cancelled the stream while asking the PC what it runs", "Stream")
        streamCheckTask?.cancel()
        streamCheckTask = nil
        streamCheckToken = nil
        streamCheckHostID = nil
        return true
    }

    /// One INFO adjudicating the 400 ms connect hold at the live edge: the
    /// click→established span plus whether the capsule mounted. In testing
    /// the suppress-flash promise could not be verified from any artifact
    /// (the engine clock misses HTTPS + window build); this makes the
    /// verdict one grep. No-op when the click anchor was already consumed
    /// (e.g. a duplicate live edge).
    private func logConnectHoldAdjudication() {
        guard let clicked = Self.connectClickedAt else { return }
        Self.connectClickedAt = nil
        let spanMs = Int(Date().timeIntervalSince(clicked) * 1000)
        let capsule = Self.connectCapsuleShown
            ? "capsule shown" : "capsule suppressed (established inside the hold)"
        Diag.info("Connect hold - click→established \(spanMs) ms · \(capsule)", "Stream")
    }

    // MARK: - Stream-ended toast copy

    /// Display line for the stream-ended toast. `summaryLine`'s integer
    /// rounding renders a sub-millisecond wired median as "0 ms median" -
    /// which reads like a broken measurement when it's actually the best
    /// number the link can post. Present those as "<1 ms median"; everything
    /// else passes through unchanged.
    var lastSessionReceiptToastLine: String? {
        guard let receipt = lastSessionReceipt else { return nil }
        guard let rtt = receipt.medianRttMs, Int(rtt.rounded()) < 1 else {
            return receipt.summaryLine
        }
        // The duration is always summaryLine's first " · " segment - reuse it
        // so the duration formatting stays single-sourced in SessionReceipt.
        let duration = receipt.summaryLine.components(separatedBy: " · ").first
            ?? receipt.summaryLine
        return "\(duration) · <1 ms median"
    }
}
