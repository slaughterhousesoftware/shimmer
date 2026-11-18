//
//  StreamWindow+Show.swift
//
//  StreamWindow.show() - the bring-up of the stream window - plus the display
//  observers that keep the frame pacer on the live display, and the hide a
//  pop-out to Picture in Picture uses. Split out of StreamWindow.swift; see
//  that file for the window's stored state.
//

import AppKit
import os.log

extension StreamWindow {

    /// Bring the stream up: activate, order the window front (invisible until
    /// the first frame), install input next runloop, and take it into full
    /// screen if that's how the user left the last stream. A 1.5 s backstop
    /// re-asks for key status.
    public func show() {
        if launchesInPictureInPicture {
            // Configured but never ordered in: the stream opens in Picture in
            // Picture and the app the user is in stays in front.
            configureWindowedChrome()
            window.alphaValue = 0.0
            awaitingFirstFrameFadeIn = true
            installWindowedLifecycleObservers()
            beginLaunchIntoPictureInPicture()
            return
        }
        AppDelegate.refreshActivationPolicy()   // a stage of our own, not behind the focused one
        NSApp.activate()
        configureWindowedChrome()
        // An empty display layer renders black, so the window stays invisible
        // until video exists (fadeInOnFirstFrame).
        window.alphaValue = 0.0
        awaitingFirstFrameFadeIn = true
        window.makeKeyAndOrderFront(nil)
        installWindowedLifecycleObservers()
        // The way the user left the last stream (StreamWindow+FullScreen).
        enterRememberedFullScreen()
        let size = window.contentRect(forFrameRect: window.frame).size
        log.info(
            "Stream window up - content \(size.width, privacy: .public)×\(size.height, privacy: .public) pt")
        // Install input next runloop (didClose guard: a connect that fails
        // first must not re-capture). A full-screen entry re-installs it once
        // the Space is up, since the transition resets the responder chain.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didClose else { return }
            self.onDidBecomeReadyForInput?()
        }
        // Key backstop: a window can be on screen and still not key if the app
        // wasn't active at makeKeyAndOrderFront. Not once it's hidden on
        // purpose (Picture in Picture) - activating would read as a return.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.didClose, !self.isBackgrounded, !self.window.isKeyWindow else { return }
            self.log.error("Window not key 1.5s after show(); retrying activate + makeKeyAndOrderFront + first-responder install")
            // A stream that comes up long after the click that asked for it (a
            // PS5 waking, a wake-then-connect) has no click left to activate
            // with: a plain activate() is refused, and the window sat on
            // screen without the keyboard until it was clicked. Activate the
            // way the PiP return does, and keep asking until it holds.
            Self.forceActivate()
            self.window.orderFrontRegardless()   // on top even when activation is refused
            self.window.makeKeyAndOrderFront(nil)
            self.onDidBecomeReadyForInput?()
            self.reassertActivation(attempt: 0)
        }
    }

    /// A screen change, a same-screen mode/HDR/VRR reconfiguration, and a
    /// display wake all rebind the FramePacer's CADisplayLink and re-assert
    /// the cursor hide.
    func installDisplayObservers(nc: NotificationCenter) {
        // Screen-change: the window was dragged to another display (or its
        // backing display's mode changed / woke from sleep). Notify the owner
        // so the FramePacer rebinds its CADisplayLink to the new screen's
        // cadence. AppKit's NSView.displayLink already follows the view across
        // screens in the common case, but a hard mode change / sleep-wake can
        // leave the old link silently stopped - rebinding is the safe fix.
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose else { return }
                self.log.info("Stream window changed screen - rebinding pacer link")
                self.onScreenChanged?()
                // A display swap can make the WindowServer re-show the cursor
                // behind the one-shot hide latch; re-assert (no-op unless we're
                // the desired-hidden owner and the OS re-showed it).
                self.reassertCursorHiddenIfNeeded()
            }
        })
        // Same-screen display reconfiguration. `didChangeScreenNotification`
        // ONLY fires when the window's backing NSScreen changes (a cross-
        // display drag). It does NOT fire for a display MODE / HDR / VRR
        // transition on the SAME external panel - exactly the 4K240 HDR/VRR
        // "first HDR engagement" case that silently stopped the CADisplayLink
        // and hard-froze the stream. `NSApplication.didChangeScreenParameters`
        // DOES fire on those mode/HDR/VRR changes (the display's parameters
        // changed even though the window stayed on it), so route it to the same
        // pacer-rebind path. Object is nil - it's an app-wide notification.
        keyObservers.append(nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose else { return }
                self.log.info("Screen parameters changed (mode/HDR/VRR) - rebinding pacer link")
                self.onScreenChanged?()
                // This is exactly the HDR/VRR-engage reconfig that makes
                // the WindowServer re-show the cursor mid-stream. Re-assert the
                // hide here so it's repaired before the next mouse move (no-op
                // unless we're the desired-hidden owner and the OS re-showed it).
                self.reassertCursorHiddenIfNeeded()
            }
        })
        // Display wake. The link can silently stop across a display sleep on
        // the external panel and is never rebuilt by either notification above
        // (no screen swap, no parameter change on wake in some configs). The
        // workspace screens-did-wake notification is the reliable signal.
        // Lives on NSWorkspace.shared.notificationCenter, NOT the default
        // center - a common gotcha. Tracked in `workspaceObservers` so close()
        // removes it from the right center.
        let wsnc = NSWorkspace.shared.notificationCenter
        // Display sleep: nothing is on screen until the wake below. Sound
        // keeps playing; the picture stops being decoded and presented.
        workspaceObservers.append(wsnc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose else { return }
                self.log.info("Displays asleep - present suppressed until they wake")
                self.displaysAsleep = true
                self.publishPresentSuppression()
            }
        })
        workspaceObservers.append(wsnc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose else { return }
                self.log.info("Displays woke - rebinding pacer link")
                self.displaysAsleep = false
                self.publishPresentSuppression()
                self.onScreenChanged?()
                // Display sleep-wake re-shows the cursor behind the latch too;
                // re-assert the hide (no-op unless we're the desired-hidden owner
                // and the OS re-showed it).
                self.reassertCursorHiddenIfNeeded()
            }
        })
    }

    /// Hide the window for Picture in Picture: cursor back, window ordered
    /// out, launcher told. PiP shows its own layer (PiPSource), so the window
    /// needn't stay on screen. Never called inside a full-screen Space -
    /// `enterPictureInPicture()` steps out of it first.
    func hideStreamWindow(forPictureInPicture: Bool = false) {
        PiPTrace.log("hideStreamWindow forPiP=\(forPictureInPicture) backgrounded=\(isBackgrounded)", window)
        guard !isBackgrounded else { return }
        isBackgrounded = true
        setCursorHidden(false)
        if forPictureInPicture { log.info("Stream window hidden for Picture in Picture") }
        window.orderOut(nil)
        onBackgroundedChanged?(true)
    }
}
