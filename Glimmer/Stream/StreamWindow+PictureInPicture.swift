//
//  StreamWindow+PictureInPicture.swift
//
//  Picture in Picture orchestration for the stream window: entering (hotkey /
//  menu bar / automatically on switch-away / a stream that opens in PiP), the
//  AVKit edge handlers, the return path, and the present-suppression state the
//  decoder is told about.
//
//  Model
//  -----
//  Apple's PiP shows a layer of its own (`PiPSource`), fed the same decoded
//  frames as the stream window. The stream window is simply hidden (ordered
//  out, as for a Cmd-Tab away) while PiP is up, and shown again on return:
//
//      visible ──hide──▶ hidden ──start──▶ PiP ──stop(return)──▶ visible
//                          ▲                 │
//                          └──stop(×)────────┘
//
//  `PiPPanelFitter` keeps the picture whole inside Apple's PiP window (the
//  unscaled-mirror bug, FB22411168). Nothing about the stream window changes
//  for PiP any more - no shrinking, no transparency, no reshaping.
//
//  Present suppression - "nobody is looking, stop presenting and after 2 s
//  stop decoding" - is a function of the PiP bits (`presentSuppressedState`):
//  hidden AND not in/entering PiP, OR paused from the PiP controls.
//
//  While PiP is up:
//    * the frame pacer runs on a screen link, and frames go only to the PiP
//      layer - the owner does both from `onPictureInPictureChanged`;
//    * `GCController.shouldMonitorBackgroundEvents` is on so the gamepad keeps
//      reaching the host while another app is frontmost.
//

import AppKit
import GameController
import os.log

/// Debug-only file trace for the PiP hide / return paths, gated on the
/// `--debug-pip-probe` knob (never on for a normal launch). The unified log
/// can be unavailable on a test machine; this appends one line per decision
/// to /tmp/shimmer-pip-trace.log so a sequence can be reconstructed exactly.
enum PiPTrace {
    static let enabled: Bool = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--debug-pip-probe") }
        || ProcessInfo.processInfo.environment["GLIMMER_DEBUG_PIP_PROBE"] != nil
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    @MainActor static func log(_ what: String, _ w: NSWindow? = nil) {
        guard enabled else { return }
        var line = "\(fmt.string(from: Date())) \(what) active=\(NSApp.isActive)"
        if let w { line += " key=\(w.isKeyWindow) visible=\(w.isVisible) alpha=\(w.alphaValue) level=\(w.level.rawValue) frame=\(Int(w.frame.origin.x)),\(Int(w.frame.origin.y)) \(Int(w.frame.width))x\(Int(w.frame.height))" }
        line += "\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/shimmer-pip-trace.log") { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { FileManager.default.createFile(atPath: "/tmp/shimmer-pip-trace.log", contents: line.data(using: .utf8)) }
    }
}

extension StreamWindow {

    // MARK: - Entry

    /// Pop the stream out into the system Picture in Picture window. Hides the
    /// stream window first if it is up (same teardown as a Cmd-Tab-away).
    /// No-op when PiP is already up / starting, or when AVKit can't start it.
    public func enterPictureInPicture() {
        PiPTrace.log("enterPictureInPicture backgrounded=\(isBackgrounded) active=\(isPictureInPictureActive) pending=\(pictureInPicturePending) possible=\(pictureInPicture.isPossible)", window)
        guard !didClose, !isPictureInPictureActive, !pictureInPicturePending else { return }
        // Opening straight into PiP: the launch starts it once frames exist.
        guard !launchingIntoPiP else { return }
        // Before the first frame the layer has no video size, and AVKit's PiP
        // host view lays out at a NaN origin - AppKit traps on it (crash
        // 2026-10-04: a switch-away a second after Stream).
        guard !awaitingFirstFrameFadeIn else {
            log.notice("Picture in Picture requested before the first frame - ignored")
            return
        }
        // A window can't be hidden inside its full-screen Space: step out
        // first (not the user's choice - the return goes back in), then pop.
        if isFullScreen, !isBackgrounded {
            leaveFullScreen { [weak self] in self?.enterPictureInPicture() }
            return
        }
        guard preparePiPSource() else {
            log.notice("Picture in Picture requested but not possible (another app may own it)")
            if pipStartIsLaunch { showWindowAfterFailedPiPLaunch("Picture in Picture isn't possible right now") }
            return
        }
        if !isBackgrounded { hideStreamWindow(forPictureInPicture: true) }
        startPictureInPictureNow()
        publishPresentSuppression()
    }

    /// The source at the stream's own resolution - every decoded pixel
    /// reaches the PiP window - centred where AVKit's opening animation should
    /// grow from: the stream window, or where the PiP window last was for a
    /// stream that never showed its window. Never resized while PiP is up
    /// (measured: a resize mid-PiP shows the old fit for ~9 frames).
    func pipStartFrame() -> NSRect {
        let center: CGPoint
        if pipStartIsLaunch {
            let spot = Self.rememberedPiPPanelFrame() ?? {
                // First ever: about where macOS puts a new PiP window.
                let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                return NSRect(x: screen.maxX - 500, y: screen.maxY - 300, width: 480, height: 270)
            }()
            center = CGPoint(x: spot.midX, y: spot.midY)
        } else {
            let frame = window.frame
            center = CGPoint(x: frame.midX, y: frame.midY)
        }
        return pipSourceFrame(centeredOn: center)
    }

    /// Every PiP entry starts here: the source on screen (AVKit mirrors only
    /// an on-screen layer, and `isPossible` reflects that), where the opening
    /// animation should grow from. False - and the source off screen again -
    /// when AVKit can't start PiP now.
    @discardableResult
    func preparePiPSource() -> Bool {
        if !pipSource.isOnScreen { pipSource.show(at: pipStartFrame()) }
        pipSourceMode = true
        guard pictureInPicture.isPossible else {
            pipSource.hide()
            pipSourceMode = false
            return false
        }
        return true
    }

    /// Where the stream window shows its picture, in screen coordinates: the
    /// stream's aspect fitted into the window's content area.
    func pipReturnTarget() -> NSRect {
        let content = window.contentRect(forFrameRect: window.frame)
        return StreamWindowGeometry.aspectFit(streamPixelSize, in: content)
    }

    func pipSourceFrame(centeredOn center: CGPoint) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? window.screen ?? NSScreen.main
        return PiPSource.nativeFrame(pixelSize: streamPixelSize, backingScale: screen?.backingScaleFactor ?? 2,
                                     center: center, screen: screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
    }

    /// Ask AVKit to start. `pictureInPicturePending` keeps present suppression
    /// off for the ~100ms until didStart / failedToStart resolves it; a
    /// backstop clears it if AVKit never answers.
    func startPictureInPictureNow() {
        guard !isPictureInPictureActive, !pictureInPicturePending else { return }
        guard preparePiPSource() else {
            log.notice("Picture in Picture not possible - staying hidden")
            return
        }
        PictureInPictureStage.shared.claim(by: self)
        installPictureInPictureHandlers()
        pictureInPicturePending = true
        // Pacer on a screen link and frames to the PiP layer only, before AVKit
        // brings its window up (~100-300 ms).
        onPictureInPictureChanged?(true)
        pictureInPicture.start()
        // Find and fit the panel from its first frame, before didStart.
        pipFitter.attach()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pictureInPicturePending else { return }
                self.log.error("Picture in Picture start never resolved - clearing pending state")
                self.pictureInPicturePending = false
                self.leavePiPSource()
                self.onPictureInPictureChanged?(false)
                self.publishPresentSuppression()
                self.showWindowAfterFailedPictureInPicture("the start never resolved")
            }
        }
    }

    /// Picture in Picture didn't start. The window was hidden for it, so
    /// without this the stream went on with sound and no picture anywhere -
    /// only a launch straight into PiP used to get its window back.
    func showWindowAfterFailedPictureInPicture(_ why: String) {
        guard !didClose else { return }
        if pipStartIsLaunch {
            showWindowAfterFailedPiPLaunch(why)
            return
        }
        guard isBackgrounded else { return }
        log.notice("Picture in Picture didn't start (\(why, privacy: .public)) - showing the stream window again")
        Self.becomeRegularApp()
        NSApp.activate()
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        reengageForeground()
        reassertActivation(attempt: 0)
    }

    // MARK: - AVKit edges

    func installPictureInPictureHandlers() {
        pipFitter.onPanelChanged = { [weak self] panel in
            guard let self else { return }
            self.pipKeepAlive?.stop()
            self.pipKeepAlive = panel?.contentView.map { PiPKeepAlive(in: $0) }
            self.onPictureInPicturePanelChanged?(panel)
        }
        pictureInPicture.onDidStart = { [weak self] in
            guard let self, !self.didClose else { return }
            self.pictureInPicturePending = false
            self.pipStartIsLaunch = false
            self.setPictureInPictureActive(true)
            // Came back to the window while PiP was still starting - the
            // window wins; collapse the PiP that just appeared. NOT
            // synchronously: a stop issued inside AVKit's didStart callback is
            // silently dropped, and so is every later one (macOS 26).
            if !self.isBackgrounded {
                self.log.info("Picture in Picture started after the window returned - stopping it")
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.didClose, !self.isBackgrounded else { return }
                    self.pictureInPicture.stop()
                }
                return
            }
            self.enableBackgroundControllerEvents()
            PictureInPictureStage.shared.rateSampler.start(layer: self.pipLayer)
            // Normally already attached (from the start request); a no-op then.
            if self.pipFitter.panel == nil { self.pipFitter.attach() }
            self.publishPresentSuppression()
        }
        pictureInPicture.onFailedToStart = { [weak self] _ in
            guard let self, !self.didClose else { return }
            self.pictureInPicturePending = false
            self.leavePiPSource()
            self.onPictureInPictureChanged?(false)
            self.publishPresentSuppression()
            self.showWindowAfterFailedPictureInPicture("AVKit refused to start")
        }
        pictureInPicture.onRestoreRequested = { [weak self] ready in
            // The PiP window's return button: AVKit flies back on `ready`.
            guard let self else { ready(); return }
            self.returnFromPictureInPicture(fromPanel: true, ready: ready)
        }
        pictureInPicture.onDidStop = { [weak self] restoreRequested in
            guard let self, !self.didClose else { return }
            PiPTrace.log("onDidStop restoreRequested=\(restoreRequested) backgrounded=\(self.isBackgrounded) inFlight=\(self.pipReturnInFlight)", self.window)
            self.setPictureInPictureActive(false)
            self.pictureInPicturePaused = false
            PictureInPictureStage.shared.rateSampler.stop()
            self.restoreBackgroundControllerEvents()
            self.leavePiPSource()
            self.onPictureInPictureChanged?(false)
            // × close: the stream window stays hidden (it already is), and the
            // normal hidden-window suppression engages. Return: no-op.
            self.publishPresentSuppression()
        }
        pictureInPicture.onPauseChanged = { [weak self] paused in
            guard let self, !self.didClose else { return }
            self.pictureInPicturePaused = paused
            self.publishPresentSuppression()
        }
    }

    /// PiP is over (or never started): the source leaves the screen and the
    /// fitter lets go of the panel. Idempotent.
    func leavePiPSource() {
        pipFitter.detach()
        pipSource.hide()
        pipSourceMode = false
    }

    /// Bring the stream window back from PiP - the PiP window's return control,
    /// the menu bar's "Back to", the launcher.
    ///
    /// The window comes forward FIRST - Shimmer active, the user switched to
    /// the desktop the window lives on - and only then does the picture fly
    /// back, into a window that is on screen and already live. (Earlier the
    /// PiP flew to a window in a space the user wasn't looking at, and
    /// vanished: after the PiP's return control macOS refused activation for
    /// the full 3 s, measured 2026-11-16 with T3 Code full screen.)
    ///
    /// `fromPanel`: AVKit is already stopping; `ready` lets it finish (fly
    /// back) - see StreamPictureInPicture.onRestoreRequested.
    func returnFromPictureInPicture(fromPanel: Bool = false, ready: (@MainActor () -> Void)? = nil) {
        guard !didClose else { ready?(); return }
        PiPTrace.log("returnFromPictureInPicture fromPanel=\(fromPanel) backgrounded=\(isBackgrounded)", window)
        // Over another app's full screen, stay a menu-bar app: macOS keeps a
        // Dock app's window off another app's full-screen Space and switches
        // the user to a desktop to show it (measured 2026-11-16 - the
        // "jumps to my other screen" return). An accessory app's window
        // joins the full-screen Space where the user is.
        // Not when the stream goes back into full screen itself: it takes its
        // own Space then, and an auxiliary window could not.
        let overFullScreen = !StreamFullScreenMemory.opensFullScreen()
            && MenuBarController.frontmostAppIsFullScreen()
        if !overFullScreen { Self.becomeRegularApp() }
        pipReturnInFlight = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            MainActor.assumeIsolated { self?.pipReturnInFlight = false }
        }
        // Apple's model: the window waits, black, while the picture flies back
        // into it, and takes over the video only once PiP has stopped (didStop
        // hands the frames back). Clear the frame it showed before PiP.
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        // The window comes to the user: on every Space for the return (over a
        // full-screen app too), so it is already on the one they are looking
        // at when the app activates - macOS has no other Space to switch to.
        // Floating and unmanaged until then: Stage Manager files an inactive
        // app's window into the strip.
        if savedShapeBeforePiP == nil { savedShapeBeforePiP = (window.level, window.collectionBehavior) }
        returnedOverFullScreenApp = overFullScreen
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.level = .floating
        window.alphaValue = 1
        window.orderFrontRegardless()
        // Activate only once the window is on this Space, so
        // activation has nowhere else to take the user.
        Self.forceActivate()
        isBackgrounded = false
        publishPresentSuppression()
        onBackgroundedChanged?(false)
        let started = Date()
        awaitWindowForward(attempt: 0) { [weak self] in
            guard let self else { ready?(); return }
            Diag.info("PiP return: window forward=\(NSApp.isActive && self.window.isOnActiveSpace) "
                + "after \(Int(Date().timeIntervalSince(started) * 1000)) ms", "Stream.PiP")
            // AVKit's fly-back ends on the source layer's rect: exactly over
            // the window's picture, now on the screen the user is looking at.
            self.pipSource.place(at: self.pipReturnTarget())
            self.presentReturnedWindow()
            // The PiP flies back now: AVKit's own return finishes, or ours
            // (menu bar) stops it (reengageForeground; a no-op when stopping).
            ready?()
            // didStop hands the frames back to the window. If AVKit never
            // reports it, don't leave the window black.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.didClose, !self.isBackgrounded,
                          self.isPictureInPictureActive || self.pictureInPicturePending else { return }
                    Diag.warn("PiP return: no didStop 2 s after the fly-back - giving the window its frames", "Stream.PiP")
                    self.onPictureInPictureChanged?(false)
                }
            }
            if !fromPanel, self.isPictureInPictureActive || self.pictureInPicturePending {
                self.pictureInPicture.stop()
            }
        }
    }

    /// Wait (up to ~1.5 s) until Shimmer is active and the window is in the
    /// space on screen, re-asking every 30 ms; then `then`. On timeout carry
    /// on anyway - a window the user can find beats a return that never ends.
    func awaitWindowForward(attempt: Int, then: @escaping @MainActor () -> Void) {
        guard !didClose else { then(); return }
        if (NSApp.isActive && window.isOnActiveSpace) || attempt >= 50 {
            then()
            return
        }
        if attempt == 10 { Self.forceActivate() }   // once more, if the first was early
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated { self?.awaitWindowForward(attempt: attempt + 1, then: then) }
        }
    }

    /// Come forward without a fresh user click: cooperative activation
    /// ignores `NSApp.activate()` then (after the PiP's return control it was
    /// refused for 3 s), but a LaunchServices open of the running app is
    /// honoured - measured: active and on the window's space within 0.3 s,
    /// over a full-screen app. The reopen that sends is ignored
    /// (`AppDelegate.suppressReopenUntil`).
    static func forceActivate() {
        NSApp.activate()
        AppDelegate.suppressReopenUntil = Date().addingTimeInterval(2)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { Diag.warn("PiP return: LaunchServices activation failed: \(error.localizedDescription)", "Stream.PiP") }
        }
    }

    /// Re-request activation (and key) every 50 ms until the app is active,
    /// up to ~3 s. The window is already on screen; this only makes it key.
    func reassertActivation(attempt: Int) {
        guard !didClose, !isBackgrounded else { return }
        if NSApp.isActive {
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            return
        }
        guard attempt < 60 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.didClose, !self.isBackgrounded else { return }
                NSApp.activate()
                self.window.makeKeyAndOrderFront(nil)
                self.reassertActivation(attempt: attempt + 1)
            }
        }
    }

    /// The window's level + collection behaviour from before the return's
    /// floating shape. No-op when already restored.
    func restorePiPSourceShape() {
        guard let shape = savedShapeBeforePiP else { return }
        // Back to an ordinary window on the Space it was brought to. Over
        // another app's full screen it stays an auxiliary window there (an
        // ordinary one would be sent to a desktop Space, taking the user
        // with it), and follows the user if they move on.
        window.collectionBehavior = returnedOverFullScreenApp
            ? [.fullScreenAuxiliary, .moveToActiveSpace]
            : shape.behavior
        window.level = shape.level
        savedShapeBeforePiP = nil
    }

    /// The second half of a return: back to the normal window
    /// shape, key + front, foreground re-engaged. Idempotent.
    func presentReturnedWindow() {
        guard !didClose else { return }
        restorePiPSourceShape()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        reengageForeground()
        PiPTrace.log("presentReturnedWindow: presented", window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                self?.pipReturnInFlight = false
                // Back into full screen if that's how the user had it.
                self?.enterRememberedFullScreen()
            }
        }
    }

    /// Close PiP as its × does, while the stream still feeds it, then `done`.
    /// The window stays hidden; this is the first step of ending the stream.
    func closePictureInPicture(done: @escaping @MainActor () -> Void) {
        let stage = PictureInPictureStage.shared
        guard !didClose, stage.isOwned(by: self), isPictureInPictureActive || pictureInPicturePending else {
            done()
            return
        }
        log.info("Closing Picture in Picture before the stream ends")
        stage.close(by: self)
        pipSourceMode = false
        awaitStageFree(attempt: 0, then: done)
    }

    private func awaitStageFree(attempt: Int, then done: @escaping @MainActor () -> Void) {
        guard !PictureInPictureStage.shared.isFree, attempt < 60 else { done(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { done(); return }
                self.awaitStageFree(attempt: attempt + 1, then: done)
            }
        }
    }

    /// PiP teardown for `close()`: PiP closes with the stream (a Switch PC
    /// opens the next stream's own), and the controller-background flag goes
    /// back.
    func tearDownPictureInPicture() {
        pictureInPicturePending = false
        let stage = PictureInPictureStage.shared
        if stage.isOwned(by: self) {
            // As its × closes it: no fly-back to a window that's going away.
            stage.close(by: self)
            pipSourceMode = false
        }
        setPictureInPictureActive(false)
        restoreBackgroundControllerEvents()
        pipKeepAlive?.stop()
        pipKeepAlive = nil
    }

    // MARK: - Debug probe

    /// Everything the PiP state machine depends on, one line, for the
    /// env-gated `--debug-pip-probe` timer in DebugAutomation.
    public func debugPiPState() -> String {
        let panelVisible = NSApp.windows.contains {
            String(describing: type(of: $0)).contains("PIPPanel") && $0.isVisible
        }
        return "\(pictureInPicture.debugState) win.active=\(isPictureInPictureActive) pending=\(pictureInPicturePending) "
            + "sourceMode=\(pipSourceMode) source=\(Int(pipSource.window.frame.width))x\(Int(pipSource.window.frame.height)) "
            + "fits=\(pipFitter.fits) backgrounded=\(isBackgrounded) alpha=\(window.alphaValue) "
            + "frame=\(Int(window.frame.width))x\(Int(window.frame.height)) visible=\(window.isVisible) key=\(window.isKeyWindow) "
            + "appActive=\(NSApp.isActive) panelVisible=\(panelVisible)"
    }

    // MARK: - Present suppression

    /// The decoder's suppression state as a pure function of the window's
    /// PiP bits, so the truth table is unit-testable without AppKit:
    ///  * hidden and nothing is (about to be) showing the layer → suppressed;
    ///  * PiP up or starting → NOT suppressed (someone is watching);
    ///  * paused from the PiP controls → suppressed (freeze + decode gate),
    ///    regardless of the rest.
    ///  * opening straight into PiP (hidden, PiP not started yet) → NOT
    ///    suppressed: the first frames must decode to start it.
    ///  * every display asleep → suppressed, Picture in Picture or not: a
    ///    stream left running kept decoding at full rate into a dark screen
    ///    (an hour of it, measured, on a laptop).
    nonisolated static func presentSuppressedState(
        backgrounded: Bool, pipActive: Bool, pipPending: Bool, pipPaused: Bool,
        launchingIntoPiP: Bool = false, displaysAsleep: Bool = false
    ) -> Bool {
        if pipPaused || displaysAsleep { return true }
        return backgrounded && !pipActive && !pipPending && !launchingIntoPiP
    }

    /// Recompute and forward the suppression state, edge-triggered.
    func publishPresentSuppression() {
        let suppressed = Self.presentSuppressedState(
            // A miniaturized window shows nothing either (it is in the Dock).
            backgrounded: isBackgrounded || window.isMiniaturized,
            pipActive: isPictureInPictureActive,
            pipPending: pictureInPicturePending,
            pipPaused: pictureInPicturePaused,
            launchingIntoPiP: launchingIntoPiP,
            displaysAsleep: displaysAsleep)
        guard suppressed != lastEmittedPresentSuppressed else { return }
        lastEmittedPresentSuppressed = suppressed
        onPresentSuppressionChanged?(suppressed)
    }

    // MARK: - Controller in the background

    /// GameController only delivers pad input to the frontmost app unless told
    /// otherwise. While PiP is up Glimmer is by definition NOT frontmost, and
    /// "keep playing with the pad from the corner" is the whole point.
    func enableBackgroundControllerEvents() {
        guard savedControllerBackgroundFlag == nil else { return }
        savedControllerBackgroundFlag = GCController.shouldMonitorBackgroundEvents
        GCController.shouldMonitorBackgroundEvents = true
        log.info("Controller background events enabled for Picture in Picture")
    }

    func restoreBackgroundControllerEvents() {
        guard let saved = savedControllerBackgroundFlag else { return }
        GCController.shouldMonitorBackgroundEvents = saved
        savedControllerBackgroundFlag = nil
    }
}

// MARK: - Recording keep-alive

/// Redraws the system PiP panel a few times a second so the picture cannot
/// stay frozen after a Stage Manager switch or Mission Control.
///
/// macOS 27.2, measured 2026-11-10: while the screen is being recorded
/// (Cmd-Shift-5, or any other display capture), a Stage Manager switch or a
/// Mission Control animation stops the window server sampling a video
/// layer's image queue - and it does not start again when the animation
/// ends. Frames keep arriving and keep being enqueued on time; the picture
/// just sits on its last one until something redraws the window showing it.
/// Hovering the pointer over the PiP was enough, which is how this was
/// found. A bare `AVSampleBufferDisplayLayer` in an ordinary window does the
/// same, so it is neither this app nor PiP. macOS 27.0 does not do it.
///
/// A Core Animation commit anywhere in the PANEL's layer tree restarts the
/// sampling. Commits in the source window's tree do not: AVKit moves the
/// video layer into the panel for as long as PiP is up. Moving, reordering,
/// flushing and re-levelling either window do not either.
///
/// So: one 1pt, 1%-opaque layer in the panel's corner (under its rounded
/// mask), nudged on a timer. The stall DURING the animation - about half a
/// second, and it holds every window on screen, video or not - is the
/// system's and cannot be shortened from here; this only bounds how long
/// AFTER it the picture stays stuck. A commit on every display refresh lost
/// the same frames as 60 Hz, so the rate buys nothing beyond that bound:
/// 20 Hz is at most 50 ms, costs nothing measurable in this process, and
/// stays inside the window server's noise.
@MainActor
final class PiPKeepAlive {
    static let interval: TimeInterval = 1.0 / 20.0

    /// Layer-HOSTING (layer assigned before `wantsLayer`), so the tree under
    /// it is ours to mutate; AppKit owns the panel's own backing layers.
    private let host = PassThroughView(frame: NSRect(x: 0, y: 0, width: 2, height: 1))
    private let dot = CALayer()
    private var timer: Timer?
    private var flip = false

    init(in panelContent: NSView) {
        host.layer = CALayer()
        host.wantsLayer = true
        dot.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        dot.backgroundColor = CGColor(gray: 0, alpha: 0.01)
        host.layer?.addSublayer(dot)
        panelContent.addSubview(host)
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.nudge() }
        }
        timer.tolerance = Self.interval / 4
        // .common: keep going while the user drags or resizes the PiP.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// One commit in the panel's tree. The dot moves between two positions a
    /// point apart; the change has to be real, or nothing is committed.
    func nudge() {
        flip.toggle()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.position = CGPoint(x: flip ? 1.5 : 0.5, y: 0.5)
        CATransaction.commit()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        host.removeFromSuperview()
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
