//
//  StreamWindow+Windowed.swift
//
//  The stream as a real titled window: its opening size (1:1 with the
//  stream's pixels), the frame it remembers, the red button, and the pointer.
//  Full screen is the same window in a macOS Space (StreamWindow+FullScreen).
//
//  The pointer is GRABBED while it is over the picture - hidden cursor,
//  relative aim - the way a VM window or a game behaves, and given back by a
//  held Esc, the pointer chord, or switching apps. Off the picture it is a
//  normal Mac pointer, mirrored onto the host as absolute positions. In full
//  screen the picture is the screen, so it stays grabbed. InputForwarder owns
//  the engagement and the grab rule; it reports each edge through
//  `setPointerCaptured(_:)` and this file keeps VISIBILITY in the single
//  `setCursorHidden` owner - the one-owner rule the cursor latch depends on.
//  The hint that teaches the way out lives in StreamWindow+PointerAffordances.
//

import AppKit

extension StreamWindow {

    /// The frame autosave name. One name for the one stream window: position
    /// and size persist across sessions and launches, and the pixel-mapped
    /// opening size only applies until the user has moved or resized it once.
    static let frameAutosaveName = "GlimmerStreamWindow"

    /// Title, aspect lock, minimum size, and the opening frame.
    ///
    /// The window ALWAYS opens at the stream's resolution 1:1 - content points
    /// = pixels / backingScale, so a 1080p stream lands on exactly 1920x1080
    /// physical pixels (960x540 pt on a 2x panel), 1440p on 2560x1440, 4K on
    /// 3840x2160: each stream pixel on one screen pixel, no scaling blur,
    /// whatever resolution the stream is set to. The frame-autosave is kept for
    /// POSITION only - the window reopens where the user last put it, but at the
    /// resolution's size, not whatever size they last dragged to (which is what
    /// broke the pixel density before). A 4K request on a smaller panel is
    /// scaled DOWN to fit, preserving aspect.
    func configureWindowedChrome() {
        window.title = windowTitle
        let aspect = streamPixelSize.width > 0 && streamPixelSize.height > 0
            ? streamPixelSize : CGSize(width: 16, height: 9)
        window.contentAspectRatio = aspect
        window.contentMinSize = StreamWindowGeometry.minimumContentSize(aspect: aspect)
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let available = availableContentArea(on: screen)
        let mapped = StreamWindowGeometry.fitted(
            StreamWindowGeometry.pixelMappedContentSize(
                pixelWidth: Int(streamPixelSize.width), pixelHeight: Int(streamPixelSize.height),
                backingScaleFactor: screen?.backingScaleFactor ?? 1),
            within: available)
        window.setContentSize(mapped)
        if let screen {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        }
        // `setFrameAutosaveName` restores a previously saved frame as a side
        // effect (and returns false if another live window holds the name -
        // close() releases it, so that only happens if a prior window leaked;
        // the window still works, it just doesn't persist its frame).
        if !window.setFrameAutosaveName(Self.frameAutosaveName) {
            log.error("Stream window frame autosave name already in use - this session's frame won't persist")
        }
        // Position from the restore, size from the resolution: force the
        // content back to the pixel-mapped size, anchored at the restored
        // top-left so the window stays where the user put it. This is what
        // makes every open 1:1 with the stream regardless of the last size the
        // user dragged to. Guarded on a real mapped size (streamPixelSize is
        // set before show(), but a zero would collapse the window).
        if mapped.width > 0, mapped.height > 0 {
            let restored = window.frame
            let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: mapped)).size
            window.setFrame(NSRect(x: restored.minX, y: restored.maxY - frameSize.height,
                                   width: frameSize.width, height: frameSize.height),
                            display: false)
        }
        window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
        // Seed the FREE-pointer state. The per-view transparent-cursor
        // backstop defaults ON because full screen hides the cursor for the
        // whole session - but a window opens with the pointer the user's own,
        // and without this the arrow would be invisible over the picture from
        // frame zero. It runs before any capture edge can fire (the hover grab
        // needs a first responder, installed a runloop turn later), so a
        // bring-up that DOES land under the pointer still ends captured: this
        // seeds free, the grab then flips it.
        (window.contentView as? StreamInputView)?.setTransparentCursorEnabled(false)
    }

    /// The visible screen area a window's CONTENT can occupy: the visible
    /// frame (menu bar and Dock excluded) minus this window's own title bar.
    private func availableContentArea(on screen: NSScreen?) -> CGSize {
        guard let screen else { return CGSize(width: 1920, height: 1080) }
        let probe = NSRect(x: 0, y: 0, width: 100, height: 100)
        let titleBar = window.frameRect(forContentRect: probe).height - probe.height
        return CGSize(width: screen.visibleFrame.width,
                      height: max(screen.visibleFrame.height - titleBar, 0))
    }

    /// Save the frame under the autosave name and release the name, so the
    /// next session's window can claim it. Skipped while still in a Space: the
    /// frame at that moment is the screen, not the window the user sized, and
    /// AppKit already saved the real one on the last move/resize.
    func finishWindowedFrameAutosave() {
        if !window.styleMask.contains(.fullScreen) {
            window.saveFrame(usingName: Self.frameAutosaveName)
        }
        window.setFrameAutosaveName("")
    }

    /// The delegate's close request (red button / Cmd-W). Handed to the
    /// session's stop() via `onCloseRequested`; nothing is closed here.
    func handleUserCloseRequest() {
        guard !didClose else { return }
        log.info("Stream window close requested by the user - stopping the session")
        onCloseRequested?()
    }

    /// InputForwarder's capture edge. Visibility stays with the
    /// single `setCursorHidden` owner; the per-view transparent cursor
    /// backstop is switched with it so a free pointer shows the arrow over the
    /// picture and a captured one never can. Entering capture spends one of
    /// the hint's few shows - the only teaching surface left now that the grab
    /// is the pointer being over the window rather than a control to press.
    func setPointerCaptured(_ captured: Bool) {
        guard !didClose else { return }
        setCursorHidden(captured)
        (window.contentView as? StreamInputView)?.setTransparentCursorEnabled(captured)
        if captured {
            showCaptureHintIfBudgetAllows()
        } else {
            hideCaptureHint()
        }
        log.info("Pointer \(captured ? "captured" : "released", privacy: .public)")
    }

    /// The window's observer set: the display observers (pacer rebind +
    /// cursor re-assert), full screen in and out, and miniaturize/deminiaturize as the
    /// backgrounded signal - a minimized window presents nothing, so the
    /// decoder's present suppression and the launcher's "Back to stream" both
    /// apply. NO key/activation observers: the window stays put when the user
    /// clicks elsewhere, which is the whole point of a window.
    func installWindowedLifecycleObservers() {
        let nc = NotificationCenter.default
        installDisplayObservers(nc: nc)
        installFullScreenObservers(nc: nc)
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose else { return }
                self.onBackgroundedChanged?(true)
                self.log.info("Stream window miniaturized - present suppressed until it returns")
            }
        })
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose else { return }
                self.onBackgroundedChanged?(false)
            }
        })
    }
}
