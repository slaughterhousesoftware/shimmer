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
        guard preparePiPSource() else {
            log.notice("Picture in Picture requested but not possible (another app may own it)")
            if pipStartIsLaunch { showWindowAfterFailedPiPLaunch("Picture in Picture isn't possible right now") }
            return
        }
        // Any resign-debounce teardown in flight is superseded by this
        // explicit hide (same token discipline as the becomeKey observer).
        resignGeneration &+= 1
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
                if self.pipStartIsLaunch { self.showWindowAfterFailedPiPLaunch("the start never resolved") }
            }
        }
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
            if self.pipStartIsLaunch { self.showWindowAfterFailedPiPLaunch("AVKit refused to start") }
        }
        pictureInPicture.onRestoreRequested = { [weak self] in
            // The PiP window's return button.
            self?.returnFromPictureInPicture(fromPanel: true)
        }
        pictureInPicture.onDidStop = { [weak self] restoreRequested in
            guard let self, !self.didClose else { return }
            PiPTrace.log("onDidStop restoreRequested=\(restoreRequested) backgrounded=\(self.isBackgrounded) inFlight=\(self.pipReturnInFlight)", self.window)
            self.setPictureInPictureActive(false)
            self.pictureInPicturePaused = false
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

    /// Bring the stream window back from PiP - identical to the launcher's
    /// "Back to stream" (`StreamSession.resumeWindow()`).
    ///
    /// `fromPanel`: the PiP window's own return control, which AVKit is
    /// already closing. Any other caller (the menu bar's "Back to") closes it
    /// here: macOS drops activation while the PiP panel is alive, and nothing
    /// else would close it until activation had landed.
    func returnFromPictureInPicture(fromPanel: Bool = false) {
        guard !didClose else { return }
        PiPTrace.log("returnFromPictureInPicture fromPanel=\(fromPanel) backgrounded=\(isBackgrounded)", window)
        // Headless during PiP: a window can't come forward from an accessory app.
        Self.becomeRegularApp()
        pipReturnInFlight = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            MainActor.assumeIsolated { self?.pipReturnInFlight = false }
        }
        // The window takes the frames again NOW, so it is live - not a frozen
        // last frame - when the PiP lands on it. (didStop repeats this; it is
        // idempotent.)
        onPictureInPictureChanged?(false)
        // AVKit's fly-back ends on the source layer's rect: put the source
        // exactly over the window's picture, so the PiP flies into the window
        // it is returning to and hands over to it in place.
        pipSource.place(at: pipReturnTarget())
        if displayMode == .window {
            // Activation is dropped while the PiP panel is alive and only
            // sticks once re-requested after it is gone, and Stage Manager
            // files an inactive app's window into the strip. So: the window
            // comes back now on a floating, unmanaged shape (Stage Manager
            // leaves those alone), and takes its normal shape - key, on the
            // active app's own stage - once activation is real.
            if savedShapeBeforePiP == nil { savedShapeBeforePiP = (window.level, window.collectionBehavior) }
            // NOT on every space: such a window still can't show in another
            // app's full-screen space, and because it counts as "here" macOS
            // never switches to the desktop where it does show - the PiP
            // landed mid-screen on nothing (2026-11-16, T3 Code full screen).
            // On its own desktop, activation takes the user there.
            window.collectionBehavior = [.transient, .ignoresCycle]
            window.level = .floating
            window.alphaValue = 1
            window.orderFrontRegardless()
            isBackgrounded = false
            publishPresentSuppression()
            onBackgroundedChanged?(false)
            if !fromPanel, isPictureInPictureActive || pictureInPicturePending {
                pictureInPicture.stop()
            }
            NSApp.activate()
            awaitActivationThenPresent(attempt: 0)
            return
        }
        // Fullscreen cover: above the menu bar, stationary - Stage Manager
        // doesn't manage it.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        reengageForeground()
        // An activate() in the same turn as the accessory -> regular flip can
        // be dropped; keep asking until it lands.
        reassertActivation(attempt: 0)
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

    /// Poll for genuine activation (up to ~3 s, re-requesting every 50 ms -
    /// early requests are refused while the panel winds down), then present.
    /// On timeout present anyway: an on-screen window the user can click
    /// beats one that never comes back.
    func awaitActivationThenPresent(attempt: Int) {
        guard !didClose else { return }
        if NSApp.isActive || attempt >= 60 {
            PiPTrace.log("awaitActivation done attempt=\(attempt)", window)
            Diag.info("PiP return: app \(NSApp.isActive ? "active" : "NOT active") after \(attempt * 50) ms; "
                + "window on the active space=\(window.isOnActiveSpace)", "Stream.PiP")
            presentReturnedWindow()
            return
        }
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.awaitActivationThenPresent(attempt: attempt + 1) }
        }
    }

    /// The window's level + collection behaviour from before the return's
    /// floating shape. No-op when already restored.
    func restorePiPSourceShape() {
        guard let shape = savedShapeBeforePiP else { return }
        window.collectionBehavior = shape.behavior
        window.level = shape.level
        savedShapeBeforePiP = nil
    }

    /// The second half of a window-mode return: back to the normal window
    /// shape, key + front, foreground re-engaged. Idempotent.
    func presentReturnedWindow() {
        guard !didClose else { return }
        restorePiPSourceShape()
        resignGeneration &+= 1
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        reengageForeground()
        PiPTrace.log("presentReturnedWindow: presented", window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.pipReturnInFlight = false }
        }
    }

    /// PiP teardown for `close()`: drop the controller silently and put the
    /// controller-background flag back.
    func tearDownPictureInPicture() {
        pictureInPicturePending = false
        pictureInPicture.invalidate()
        setPictureInPictureActive(false)
        restoreBackgroundControllerEvents()
        leavePiPSource()
        pipKeepAlive?.stop()
        pipKeepAlive = nil
        pipSource.close()
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
    nonisolated static func presentSuppressedState(
        backgrounded: Bool, pipActive: Bool, pipPending: Bool, pipPaused: Bool,
        launchingIntoPiP: Bool = false
    ) -> Bool {
        if pipPaused { return true }
        return backgrounded && !pipActive && !pipPending && !launchingIntoPiP
    }

    /// Recompute and forward the suppression state, edge-triggered.
    func publishPresentSuppression() {
        let suppressed = Self.presentSuppressedState(
            backgrounded: isBackgrounded,
            pipActive: isPictureInPictureActive,
            pipPending: pictureInPicturePending,
            pipPaused: pictureInPicturePaused,
            launchingIntoPiP: launchingIntoPiP)
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
