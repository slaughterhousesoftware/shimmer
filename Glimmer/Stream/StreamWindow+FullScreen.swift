//
//  StreamWindow+FullScreen.swift
//
//  Full screen is macOS's own: the stream is always a titled window, and the
//  green button, ⌃⌘F or View › Enter Full Screen take it into a full-screen
//  Space like any Mac app. Shimmer only remembers which way the user left it
//  (StreamFullScreenMemory), opens the next stream that way, and steps out of
//  the Space itself where a hidden or reshaped window can't live in one -
//  Picture in Picture - going back in once the window returns.
//

import AppKit

extension StreamWindow {

    var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    /// Enter/exit edges, installed with the window's other observers (and so
    /// swept by `close()` before its own exit can be mistaken for the user's).
    func installFullScreenObservers(nc: NotificationCenter) {
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fullScreenTransitionEnded(entered: true) }
        })
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fullScreenTransitionEnded(entered: false) }
        })
        streamDelegate.onFullScreenTransitionFailed = { [weak self] in
            guard let self else { return }
            self.log.error("Full-screen transition failed")
            self.fullScreenTransitionIsOurs = false
            self.runAfterFullScreenExit()
        }
    }

    private func fullScreenTransitionEnded(entered: Bool) {
        guard !didClose else { return }
        let ours = fullScreenTransitionIsOurs
        fullScreenTransitionIsOurs = false
        if StreamFullScreenMemory.shouldRemember(closing: didClose, ours: ours) {
            StreamFullScreenMemory.remember(entered)
        }
        let frame = window.frame, screen = window.screen?.frame ?? .zero
        Diag.info("Stream window \(entered ? "entered" : "left") full screen (\(ours ? "Shimmer" : "the user")) - "
            + "frame \(Int(frame.width))x\(Int(frame.height)) at y \(Int(frame.minY)), screen \(Int(screen.width))x\(Int(screen.height)), "
            + "safe top \(Int(window.screen?.safeAreaInsets.top ?? 0))", "Stream")
        if !entered, runAfterFullScreenExit() { return }
        // A Space transition resets the responder chain: hand the input view
        // back its first-responder seat, as after the window first came up.
        onDidBecomeReadyForInput?()
    }

    /// Run (and clear) what was waiting for the window to leave its Space.
    @discardableResult
    private func runAfterFullScreenExit() -> Bool {
        guard let next = afterFullScreenExit else { return false }
        afterFullScreenExit = nil
        next()
        return true
    }

    /// The user's own toggle (⌃⌘F in the stream, the agent command). The green
    /// button and the View menu reach AppKit directly; all of them land in
    /// the observers above as the user's choice.
    func toggleFullScreenByUser() {
        guard !didClose, !isBackgrounded, window.collectionBehavior.contains(.fullScreenPrimary) else { return }
        window.toggleFullScreen(nil)
    }

    /// Open the way the user left the last stream. No-op when already full
    /// screen, hidden, or in a shape that can't own a Space (a window
    /// returned onto another app's full-screen Space).
    func enterRememberedFullScreen() {
        guard !didClose, !isFullScreen, StreamFullScreenMemory.opensFullScreen() else { return }
        guard !isBackgrounded, window.collectionBehavior.contains(.fullScreenPrimary) else {
            Diag.info("Full screen remembered but not entered: "
                + (isBackgrounded ? "the window is hidden" : "the window joined another app's full screen"), "Stream")
            return
        }
        fullScreenTransitionIsOurs = true
        window.toggleFullScreen(nil)
    }

    /// Leave the Space, then `then`. Immediately when not full screen. Not the
    /// user's choice, so the next stream still opens full screen.
    func leaveFullScreen(then: @escaping @MainActor () -> Void) {
        guard isFullScreen else { then(); return }
        guard afterFullScreenExit == nil else { return }   // already on the way out
        afterFullScreenExit = then
        fullScreenTransitionIsOurs = true
        window.toggleFullScreen(nil)
    }
}
