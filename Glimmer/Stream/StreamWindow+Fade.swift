//
//  StreamWindow+Fade.swift
//
//  The stream window's two OPACITY TRANSITIONS and the teardown the
//  fade-out completes: the first-frame fade-in, and close() with its final
//  post-fade teardown. Split out of StreamWindow.swift; see that file for the
//  window's stored state, and StreamWindow+Show.swift for the bring-up this
//  pairs with. Both fades honor Reduce Motion by snapping instead of ramping.
//  MainActor throughout (AppKit).
//

import AppKit
import AVFoundation
import QuartzCore

extension StreamWindow {

    /// Animate the window from invisible (alphaValue 0) to fully visible
    /// over 350ms using the same ease-in-out timing macOS uses for app
    /// activation. Called by the session owner when VideoDecoder produces
    /// its first decoded frame. Idempotent - only runs once per show()
    /// (guarded by `awaitingFirstFrameFadeIn`), so mid-stream re-fires of
    /// the first-frame event (resolution change, decoder flush) don't
    /// re-animate an already-visible window.
    public func fadeInOnFirstFrame() {
        guard awaitingFirstFrameFadeIn else { return }
        awaitingFirstFrameFadeIn = false
        // Opening straight into Picture in Picture: the window never shows.
        if launchingIntoPiP {
            finishLaunchIntoPictureInPicture()
            return
        }
        let win = window
        // Under Reduce Motion, snap to visible instead of the 350ms fade -
        // the fade is exactly the kind of large-surface opacity ramp the
        // setting exists to suppress.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            win.alphaValue = 1.0
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            win.animator().alphaValue = 1.0
        }
    }

    /// Tear the stream window down cleanly. Safe to call more than once.
    public func close() {
        guard !didClose else { return }
        didClose = true
        // Switching PCs: the next stream follows, so don't hand off to the
        // launcher (activate + front the main window) when this one is gone.
        if Self.switchingHosts { handsOffToLauncher = false }

        // Picture in Picture first: the system PiP window is fed by our layer
        // and would otherwise outlive the session showing a frozen frame.
        tearDownPictureInPicture()

        // 1. Display-layer flush is DEFERRED to the fade completion (step 4).
        //    Flushing here (removingDisplayedImage) blanks the layer before the
        //    fade runs, so the user only ever sees an already-empty window fade
        //    out - imperceptible. Keeping the last decoded frame on screen
        //    until the fade finishes makes the fade-out land on the actual
        //    stream content, mirroring the first-frame fade-in.

        // 2. Restore the cursor. `setCursorHidden(false)` is idempotent and
        //    drives the counted CGDisplay latch strictly off `didHideCursor`,
        //    so this brings the count back to exactly 0 - never negative. The
        //    old unconditional belt-and-braces `NSCursor.unhide()` is gone:
        //    with the latch capped at 1 by the single-owner helper it could
        //    only ever over-show and corrupt the count, which is the very
        //    failure mode (cursor left invisible / over-visible) we're fixing.
        setCursorHidden(false)

        // Drop the key-status observers so we don't get a delayed
        // become/resign callback after the window has been torn down.
        for token in keyObservers {
            NotificationCenter.default.removeObserver(token)
        }
        keyObservers.removeAll()
        // Workspace observers live on NSWorkspace's own notification center -
        // remove them from THAT center, not the default one.
        let wsnc = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            wsnc.removeObserver(token)
        }
        workspaceObservers.removeAll()
        // Persist the frame under its autosave name and release the name, so
        // the next session's window can claim it (StreamWindow+Windowed).
        finishWindowedFrameAutosave()

        // 3. Out of full screen first - waiting for an entry still animating
        //    (a connect cancelled the moment the window came up) - and only
        //    then fade and order out. The window's observers are gone, so this
        //    exit is never remembered as the user choosing a window.
        window.makeFirstResponder(nil)
        // Strong: the session drops the window as it closes (see the fade).
        leaveFullScreenForClose { self.fadeOutAndFinishClose() }
    }

    /// 4. Fade out, orderOut. Fading instead of a hard orderOut gives the user
    ///    a 250ms acknowledgement that the stream ended - without the fade the
    ///    window snaps off and the launcher snaps in, which reads as a crash.
    private func fadeOutAndFinishClose() {
        let win = window

        // Under Reduce Motion, snap instead of the 250ms opacity ramp - same
        // policy as the first-frame fade-in (a large-surface opacity animation
        // is exactly what Reduce Motion asks us to drop).
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            win.alphaValue = 0.0
            finishClose()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = 0.0
        }, completionHandler: {
            // runAnimationGroup delivers the completion on the main run loop,
            // so we are already on the MainActor - assumeIsolated bridges the
            // SDK's non-isolated @Sendable handler back to MainActor state.
            MainActor.assumeIsolated { self.finishClose() }
        })
    }

    /// Final teardown step, run once the close fade has finished (or
    /// immediately under Reduce Motion). Extracted from `close()` so the fade
    /// completion handler captures no non-Sendable closure - it runs on the
    /// main run loop, so MainActor isolation is sound.
    ///
    /// Hands off to the launcher only AFTER the stream has faded out. Doing it
    /// synchronously (during the fade) brings the launcher in front of the
    /// still-fading stream window, which masks the fade entirely and reads as a
    /// hard cut. Deferring it makes the exit a real fade-out, mirroring the
    /// first-frame fade-in. `NSApp.activate()` is the macOS 14+ replacement for
    /// `activate(ignoringOtherApps:)`.
    private func finishClose() {
        // Now that the window is invisible, drop the last frame + hide it.
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) { }
        window.orderOut(nil)
        // Reset alphaValue so a future show() of this window isn't
        // invisible (defensive - close() is currently the last call).
        window.alphaValue = 1.0
        guard handsOffToLauncher else { return }
        // Shimmer lives in the menu bar: the stream closing leaves the user
        // where they are - no launcher window, no activation, so no Space
        // switch. Give focus back to the app underneath if nothing of ours is
        // left on screen.
        if NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey && $0 !== window }) {
            NSApp.hide(nil)
        }
    }
}
