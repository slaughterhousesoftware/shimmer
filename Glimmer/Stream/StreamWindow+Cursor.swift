//
//  StreamWindow+Cursor.swift
//
//  StreamWindow's cursor-visibility ownership and the foreground re-engage. The CGDisplay hide/show latch (single source of truth =
//  `didHideCursor`), the per-view transparent-cursor backstop, and the one
//  method both return-to-foreground paths funnel through. Split out of
//  StreamWindow.swift to keep each unit focused; see that file for the
//  window's stored state.
//

import AppKit
import CoreGraphics

extension StreamWindow {

    /// THE one and only entry point for hiding/showing the system cursor.
    ///
    /// We use `CGDisplayHideCursor`/`CGDisplayShowCursor` rather than
    /// `NSCursor.hide()`/`unhide()` deliberately: `NSCursor.hide()` only takes
    /// effect while the app is active AND the cursor is over one of the app's
    /// own windows, so a `becomeKey` that fires with the pointer momentarily
    /// off-content no-ops and leaves a stuck arrow on the stream. The
    /// CGDisplay pair is also a counted latch, but it does NOT require the
    /// cursor to be over our window, so the race disappears. This is the same
    /// recipe SDL uses for relative mouse mode on macOS (CGDisplayHideCursor
    /// while the cursor stays associated).
    ///
    /// Idempotent against `didHideCursor` (the single source of truth): hiding
    /// while already hidden, or showing while already shown, is a no-op. That
    /// guarantee caps the latch count at exactly 1, so the cursor can never be
    /// stranded invisible system-wide regardless of how many times key status
    /// flips. InputForwarder must never call this - visibility has exactly one
    /// owner.
    func setCursorHidden(_ hidden: Bool) {
        if hidden {
            guard !didHideCursor, !mouseInputDisabled else { return }
            CGDisplayHideCursor(CGMainDisplayID())
            didHideCursor = true
        } else {
            guard didHideCursor else { return }
            CGDisplayShowCursor(CGMainDisplayID())
            didHideCursor = false
        }
    }

    /// Flip "Disable mouse input" on a live session. Disabling shows the
    /// pointer and the arrow over the picture at once; enabling leaves the
    /// cursor to the capture edge the forwarder reports.
    func setMouseInputDisabled(_ disabled: Bool) {
        mouseInputDisabled = disabled
        guard !didClose, disabled else { return }
        setCursorHidden(false)
        (window.contentView as? StreamInputView)?.setTransparentCursorEnabled(false)
    }

    /// Re-assert invisibility when the OS may have silently re-shown the cursor
    /// while we still believe it's hidden. The WindowServer re-shows the cursor
    /// on its own for system events that do NOT cycle the window's key status -
    /// display mode / HDR / VRR reconfiguration (a 4K240 HDR panel case), display
    /// sleep-wake, HID device attach - and `setCursorHidden(true)` is then a
    /// no-op because `didHideCursor` is still true, so the one-shot CGDisplay
    /// latch never re-hides.
    ///
    /// This re-applies the per-view TRANSPARENT cursor (an invisible image),
    /// NOT a CGDisplayShowCursor→HideCursor toggle. The old "net-neutral" pair
    /// claimed it ran in one runloop turn "before any compositor frame," but the
    /// WindowServer is a separate process compositing on its OWN vsync cadence -
    /// it samples cursor state in the gap between the two CG calls and composites
    /// a frame with the arrow visible. That was the flash. Setting an invisible
    /// IMAGE has no show/hide pair, so no frame can ever paint a visible arrow -
    /// it cannot flash by construction (the same idiom SDL/Qt use).
    ///
    /// Gated on `didHideCursor` so it only re-applies "while WE want it hidden":
    /// it never fights resign/teardown (which set `didHideCursor = false` first).
    /// The transparent cursor is self-balancing - AppKit restores the system
    /// cursor the instant the pointer leaves the view - so it can never strand
    /// the cursor invisible; the CGDisplay latch's balanced show on
    /// resign/teardown remains the authoritative system-wide restore.
    ///
    /// (`CGCursorIsVisible()` exists in the SDK but is
    /// `API_DEPRECATED("No longer supported")`, so a conditional re-hide gated on
    /// it would emit a deprecation warning and rely on a value Apple marks
    /// unreliable on the modern WindowServer - we avoid it entirely.)
    func reassertCursorHiddenIfNeeded() {
        guard didHideCursor else { return }   // only while WE want it hidden
        (window.contentView as? StreamInputView)?.refreshCursor()
    }

    /// The window is back in front after being hidden (Picture in Picture,
    /// a miniaturize, a launch that opened in PiP): its own observers apply
    /// again, it is visible, any PiP goes, and the launcher hears it's back.
    /// The cursor follows pointer capture, so there is nothing to re-hide.
    /// Idempotent.
    func reengageForeground() {
        guard !didClose else { return }
        PiPTrace.log("reengageForeground backgrounded=\(isBackgrounded)", window)
        isBackgrounded = false
        pipSourceMode = false
        window.alphaValue = 1
        // Coming back to the window means the PiP window goes. Stop it AFTER
        // the window is on screen (callers order front first). Idempotent:
        // a user-initiated PiP stop that routed here is already stopping.
        if isPictureInPictureActive || pictureInPicturePending {
            pictureInPicture.stop()
        }
        publishPresentSuppression()
        onBackgroundedChanged?(false)
    }
}
