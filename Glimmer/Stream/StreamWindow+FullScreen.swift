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
            forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fullScreenTransition = .entering }
        })
        keyObservers.append(nc.addObserver(
            forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fullScreenTransition = .exiting }
        })
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
            self.fullScreenTransition = nil
            self.fullScreenTransitionIsOurs = false
            self.runAfterFullScreenExit()
        }
    }

    private func fullScreenTransitionEnded(entered: Bool) {
        fullScreenTransition = nil
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
        // A Space transition resets the responder chain: hand the input view
        // back its first-responder seat, as after the window first came up.
        onDidBecomeReadyForInput?()
        if !entered { runAfterFullScreenExit() }
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
        fullScreenTransition = isFullScreen ? .exiting : .entering
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
        fullScreenTransition = .entering
        window.toggleFullScreen(nil)
    }

    /// Leave the Space, then `then`. Immediately when not full screen. Not the
    /// user's choice, so the next stream still opens full screen.
    func leaveFullScreen(then: @escaping @MainActor () -> Void) {
        guard isFullScreen else { then(); return }
        guard afterFullScreenExit == nil else { return }   // already on the way out
        afterFullScreenExit = then
        fullScreenTransitionIsOurs = true
        fullScreenTransition = .exiting
        window.toggleFullScreen(nil)
    }

    // MARK: - Closing

    /// Get out of full screen for a close, then `finish`: never order the
    /// window out inside a Space or on its way into one (FullScreenClose).
    /// The observers are close()'s own - the window's were swept already, so
    /// nothing here is remembered as the user's choice. A 3 s backstop
    /// finishes anyway if AppKit never reports back. Holds `self` strongly
    /// until it finishes: the session lets go of the window as it closes,
    /// and the exit and fade must still run.
    func leaveFullScreenForClose(then finish: @escaping @MainActor () -> Void) {
        let step = FullScreenClose.step(inFullScreen: isFullScreen, transition: fullScreenTransition)
        guard step != .fade else { finish(); return }
        log.info("Closing from full screen (\(String(describing: step), privacy: .public))")
        var finished = false
        let done: @MainActor (String) -> Void = { why in
            guard !finished else { return }
            finished = true
            self.log.info("Closing from full screen: \(why, privacy: .public)")
            self.removeCloseFullScreenObservers()
            self.streamDelegate.onFullScreenTransitionFailed = nil
            finish()
        }
        let nc = NotificationCenter.default
        closeFullScreenObservers.append(nc.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { _ in
            // Next turn: AppKit ignores a toggle from inside its own
            // did-enter callback.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.log.info("Closing from full screen: arrived, leaving")
                    self.window.toggleFullScreen(nil)
                }
            }
        })
        closeFullScreenObservers.append(nc.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { done("left") }
        })
        streamDelegate.onFullScreenTransitionFailed = { done("transition failed") }
        if step == .leaveThenFade { window.toggleFullScreen(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { done("timed out") }
        }
    }

    private func removeCloseFullScreenObservers() {
        for token in closeFullScreenObservers { NotificationCenter.default.removeObserver(token) }
        closeFullScreenObservers.removeAll()
    }
}
