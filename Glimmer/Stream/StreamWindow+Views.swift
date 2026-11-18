//
//  StreamWindow+Views.swift
//
//  The AppKit support types backing StreamWindow: the window, its delegate
//  (the red button and full-screen failures), and the
//  AVSampleBufferDisplayLayer-hosting container view. Split out of
//  StreamWindow.swift; see that file for the window's stored state.
//

import AppKit

/// The stream's NSWindow. A titled window can become key on its own; the
/// overrides keep that true whatever its style, so the responder chain always
/// delivers keyDown / flagsChanged / mouseMoved to the content view.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class StreamWindowDelegate: NSObject, NSWindowDelegate {
    /// The user asked to close (red button / Cmd-W). The owner routes it to
    /// the session's stop(); the window is NOT closed here.
    var onCloseRequested: (() -> Void)?

    /// Refuse the close and hand it to the session instead: letting AppKit
    /// close the window would orderOut a still-live stream (headless session,
    /// no /cancel - the orphan issue #84 describes) and skip the fade-out
    /// teardown `StreamWindow.close()` owns.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCloseRequested?()
        return false
    }

    /// AppKit gave up on entering or leaving full screen: no did-notification
    /// follows, so whatever waited on one must not wait forever.
    var onFullScreenTransitionFailed: (() -> Void)?
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { onFullScreenTransitionFailed?() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { onFullScreenTransitionFailed?() }
}

/// View that hosts the AVSampleBufferDisplayLayer.
///
/// InputForwarder later wraps this view inside a custom StreamInputView (as a
/// subview) and makes that view the window's first responder. This view must
/// therefore *not* accept first responder, or AppKit will route key/mouse
/// events here instead of to StreamInputView and the input pipeline goes
/// silent.
///
/// Layout-wise, the display layer is the view's root layer; AppKit keeps the
/// layer's frame in sync with the view bounds automatically as the window
/// resizes, so we don't need a custom `layout` override.
final class DisplayContainerView: NSView {
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { false }
}
