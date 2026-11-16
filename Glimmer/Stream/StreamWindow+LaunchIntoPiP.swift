//
//  StreamWindow+LaunchIntoPiP.swift
//
//  Opening a stream straight into Picture in Picture (Settings › Streaming).
//
//  The window is set up as usual but never shown: no activation, no cursor
//  hide, no presentation options, so the app the user is in stays in front.
//  It counts as backgrounded from the start, the pacer runs on a screen link
//  and keyboard/mouse forwarding is off, as in PiP. Present suppression stays
//  off (`launchingIntoPiP`) so the first frames decode.
//
//  PiP itself starts through the same `enterPictureInPicture()` as every other
//  entry. It waits for the first frames - AVKit lays its view out at a NaN
//  origin without a video size, and AppKit traps - and the PiP source starts
//  where the PiP window last was (`pipLastPanelFrame`), so the opening
//  animation grows the picture in place.
//
//  While the stream lives only in PiP the app is headless (AppModel's
//  `streamOnlyInPictureInPicture`): every way back to the window calls
//  `becomeRegularApp()` before it asks for activation.
//

import AppKit

extension StreamWindow {

    /// UserDefaults key: the PiP panel's last frame, screen coordinates.
    static let lastPiPPanelFrameKey = "pipLastPanelFrame"

    /// Mark the hidden window as launching into PiP. Called by show() /
    /// showWindowed() after the window is configured but not ordered in.
    func beginLaunchIntoPictureInPicture() {
        launchingIntoPiP = true
        isBackgrounded = true
        onBackgroundedChanged?(true)
        publishPresentSuppression()
        log.notice("Stream opening in Picture in Picture - the window stays hidden")
        // Next turn: the session stands the pacer up right after show().
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didClose, self.launchingIntoPiP else { return }
            // Pacer on a screen link, keyboard/mouse forwarding off, app headless.
            self.onPictureInPictureChanged?(true)
            // First responder + focus observers; nothing is captured while the
            // window isn't key, and they are what the return path relies on.
            self.onDidBecomeReadyForInput?()
        }
    }

    /// The first frame decoded: start PiP once the layer holds video.
    func finishLaunchIntoPictureInPicture() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.didClose, self.launchingIntoPiP else { return }
                self.launchingIntoPiP = false
                self.pipStartIsLaunch = true
                self.enterPictureInPicture()
                // enterPictureInPicture can decline without starting anything
                // (it shows the window itself when PiP isn't possible).
                if self.pipStartIsLaunch, !self.pictureInPicturePending, !self.isPictureInPictureActive {
                    self.showWindowAfterFailedPiPLaunch("Picture in Picture didn't start")
                }
            }
        }
    }

    /// A launch whose PiP never came up: show the stream window instead.
    func showWindowAfterFailedPiPLaunch(_ why: String) {
        guard !didClose else { return }
        pipStartIsLaunch = false
        launchingIntoPiP = false
        log.notice("Opening in Picture in Picture failed (\(why, privacy: .public)) - showing the stream window")
        onPictureInPictureChanged?(false)
        Self.becomeRegularApp()
        NSApp.activate()
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        reengageForeground()
        reassertActivation(attempt: 0)
    }

    /// Something asked for the stream window (the menu bar's "Back to"):
    /// a launch still waiting for its first frame becomes a normal start -
    /// the window fades in on that frame.
    func prepareToComeForward() {
        if launchingIntoPiP {
            launchingIntoPiP = false
            onPictureInPictureChanged?(false)
            log.notice("Stream window requested before Picture in Picture started - opening the window instead")
        }
        Self.becomeRegularApp()
    }

    /// Headless (accessory) apps can't bring a window forward; switch first.
    /// AppModel's own refresh agrees once the stream stops being PiP-only.
    static func becomeRegularApp() {
        AppDelegate.regularHoldUntil = Date().addingTimeInterval(2)
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        Diag.info("activation policy → regular (stream window coming back)", "Launch")
    }

    // MARK: - Where the PiP window was

    static func rememberPiPPanelFrame(_ frame: NSRect) {
        guard frame.width > 50, frame.height > 50 else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: lastPiPPanelFrameKey)
    }

    /// The last PiP panel frame, if it still lies on a connected screen.
    static func rememberedPiPPanelFrame() -> NSRect? {
        guard let text = UserDefaults.standard.string(forKey: lastPiPPanelFrameKey) else { return nil }
        return validPiPFrame(NSRectFromString(text), screens: NSScreen.screens.map(\.frame))
    }

    /// `frame` if it is a sane PiP size and sits wholly on one of `screens`.
    nonisolated static func validPiPFrame(_ frame: NSRect, screens: [NSRect]) -> NSRect? {
        guard frame.width >= 100, frame.height >= 56,
              frame.width <= 4000, frame.height <= 3000,
              screens.contains(where: { $0.contains(frame) }) else { return nil }
        return frame
    }
}
