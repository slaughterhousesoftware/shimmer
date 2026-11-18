//
//  StreamWindow.swift
//
//  The NSWindow hosting the AVSampleBufferDisplayLayer that
//  VideoDecoder enqueues decoded sample buffers into. Owned by StreamSession.
//  Captures the cursor while frontmost, releases it when the user invokes
//  the quit hotkey.
//
//  Why AVSampleBufferDisplayLayer and not CAMetalLayer
//  ---------------------------------------------------
//  We tried - three times - to get correct HDR out of a CAMetalLayer driven
//  by a custom MSL fragment shader doing BT.2020 NCL YUV→RGB + range
//  scaling. On the a 4K@240 HDR1000 panel, every variant landed somewhere
//  on the same wrong axis: overbright midtones, washed highlights, milky
//  blacks. moonlight-qt on the same display, host, and content shows inky
//  blacks and proper bright highlights.
//
//  The reason: on macOS, moonlight-qt's HDR-correct path is not
//  `vt_metal.mm` (its Metal-shader fallback). The default macOS path is
//  `vt_avsamplelayer.mm`, which sidesteps Metal entirely. It hands the OS a
//  CVPixelBuffer wrapped in a CMSampleBuffer and lets AVFoundation +
//  CoreAnimation do colorspace conversion, PQ EOTF application, and EDR
//  tone-mapping against the display's actual peak luminance. There is no
//  shader. There is no manual CSC. The OS owns the pipeline end-to-end.
//
//  When you write PQ-encoded BT.2020 codes into a CAMetalLayer with a
//  custom shader, even with all the right metadata (itur_2100_PQ
//  colorspace, EDRMetadata, wantsExtendedDynamicRangeContent), the
//  compositor still has to reverse-engineer what the shader did. The
//  AVSampleBufferDisplayLayer path skips that round trip: the
//  CVPixelBuffer carries primaries / transfer / matrix attachments,
//  the CMFormatDescription carries mastering-display + content-light
//  metadata, and the layer's colorspace tells the compositor exactly
//  how to interpret the bits. No guesswork, no shader-vs-OS fight.
//
//  This is the same architectural choice moonlight-qt made on macOS and
//  the reason their HDR output is correct on the same panel.
//
//  Full screen is macOS's own (StreamWindow+FullScreen.swift): the stream is
//  always a titled window, and the green button / ⌃⌘F take it into a Space.
//  An earlier build drew its own borderless cover over the screen instead, to
//  keep Esc and the menu bar away from the game; with the pointer grabbed
//  (relative aim, cursor disassociated) the menu bar can't be reached anyway,
//  and Esc is forwarded to the game by the input view, never to AppKit.

import AppKit
import AVFoundation
import CoreGraphics
import QuartzCore
import os.log

@MainActor
public final class StreamWindow {
    let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Window")

    public let window: NSWindow
    /// The OS-driven display layer. VideoDecoder enqueues CMSampleBuffers
    /// onto this; CoreAnimation handles colorspace conversion, PQ EOTF, and
    /// EDR tone-mapping with zero shader involvement on our side.
    ///
    /// `var`, not `let`: the AVSampleBufferVideoRenderer can latch
    /// `.status == .failed` (the 4K240 HDR hard-freeze) and a bare
    /// `flush()` does not always clear it - a hard-failed renderer needs a fresh
    /// layer. `rebuildDisplayLayer()` swaps in a new one so the present-path
    /// self-heal can recover a wedge that flush alone can't. Mutated on the main
    /// actor only.
    public private(set) var displayLayer: AVSampleBufferDisplayLayer
    /// In-stream stats overlay (toggled with the user's stats hotkey). Lives
    /// as a *sublayer* of `displayLayer` so it composites above the video
    /// without breaking the AVSampleBufferDisplayLayer-as-root-layer
    /// requirement that keeps the EDR signal direct from the video layer to
    /// the window surface. Created hidden; `StreamSession`'s overlay timer
    /// drives visibility and content updates.
    public let statsOverlay: StatsOverlayLayer
    /// Top-center "Reconnecting..." banner shown over the frozen frame during a
    /// silent reconnect episode or a watchdog video-hold (the launcher's phase
    /// chip is behind this window).
    public let reconnectBanner: StreamBannerLayer
    /// Bottom-center "Network unstable" pill, auto-shown when the link enters
    /// caution/distress - independent of the full stats HUD toggle.
    public let networkBanner: StreamBannerLayer
    /// Bottom-center one-time "press <chord> to leave" toast shown on the first
    /// stream so the quit chord is discoverable (Esc is a game input).
    public let leaveHintBanner: StreamBannerLayer
    /// Bottom-center "Hold Esc to free the pointer" hint, shown over the
    /// picture for the first few captures. The sole caller is the capture
    /// edge in StreamWindow+Windowed.swift.
    public let captureHintBanner: StreamBannerLayer
    let displayView: DisplayContainerView
    /// The NSView hosting the AVSampleBufferDisplayLayer. Exposed so the
    /// session can bind the FramePacer's CADisplayLink to this view's screen
    /// (`NSView.displayLink(target:selector:)`, macOS 14+) - the link must be
    /// driven off the display the stream window actually lives on, and the
    /// view tracks that display as the window moves between screens.
    public var streamContentView: NSView { displayView }
    /// SINGLE SOURCE OF TRUTH for cursor visibility. The only authority on
    /// whether Glimmer has hidden the system cursor. Every hide/show goes
    /// through `setCursorHidden(_:)`, which drives `CGDisplayHideCursor` /
    /// `CGDisplayShowCursor` idempotently off this flag so the (counted)
    /// display-hide latch is never pushed above 1 and never left negative.
    /// InputForwarder must NEVER touch cursor visibility - it only owns
    /// relative-aim engagement (`isMouseCaptured`).
    var didHideCursor = false

    /// Settings › "Disable mouse input": the pointer stays a normal, visible
    /// Mac pointer for the whole session, so `setCursorHidden(true)` refuses.
    var mouseInputDisabled = false

    /// Observers that track stream-window key status. We hide the cursor only
    /// while the stream window is key; on Cmd-Tab-away the window resigns key
    /// status and we restore the cursor globally so the user can interact
    /// with whatever they Cmd-Tabbed to. Without these, the display-hide latch
    /// would leave the cursor invisible across the entire Mac while Glimmer is
    /// foregrounded but the stream window isn't key.
    var keyObservers: [NSObjectProtocol] = []
    /// Observers registered on `NSWorkspace.shared.notificationCenter` (a
    /// DIFFERENT center than `NotificationCenter.default`). Tracked separately
    /// so `close()` removes them from the correct center - removing a workspace
    /// observer from the default center is a silent no-op and leaks it. Used
    /// for the display-wake observer that rebinds the pacer's CADisplayLink.
    var workspaceObservers: [NSObjectProtocol] = []
    var didClose = false

    /// The window's title ("Tower - Desktop").
    public var windowTitle: String = ""

    /// The stream's requested pixel size. The window opens pixel-mapped to it
    /// (points = pixels / backingScaleFactor, fit to the screen) and locks the
    /// content aspect to it so a drag-resize scales the picture instead of
    /// letterboxing.
    public var streamPixelSize: CGSize = .zero

    /// The user closed the window (red button / Cmd-W). The session wires
    /// this to the same stop() the quit hotkey runs.
    public var onCloseRequested: (@MainActor () -> Void)?

    /// The full-screen transition under way is Shimmer's own (Picture in
    /// Picture leaving or re-entering), not the user's choice to remember.
    var fullScreenTransitionIsOurs = false
    /// What waits for the window to leave its Space (StreamWindow+FullScreen).
    var afterFullScreenExit: (@MainActor () -> Void)?
    /// A full-screen transition under way (set when one is asked for and by
    /// AppKit's will- notifications, cleared by the did- ones).
    var fullScreenTransition: FullScreenTransition?
    /// close()'s own enter/exit observers, while it walks out of a Space.
    var closeFullScreenObservers: [NSObjectProtocol] = []

    /// Monotonic stamp for the capture hint's auto-hide, so a re-capture
    /// inside the hint's ~4s life can't be cut short by the previous show's
    /// timer. See StreamWindow+PointerAffordances.swift.
    var captureHintGeneration: UInt64 = 0

    /// Called whenever the window's "is it on screen, or hidden (Picture in
    /// Picture, minimized)?" state flips. The session owner wires
    /// this to AppModel so the launcher can show a "Back to stream"
    /// affordance while the stream window is hidden.
    public var onBackgroundedChanged: (@MainActor (Bool) -> Void)?

    // MARK: Picture in Picture state (see StreamWindow+PictureInPicture.swift)

    /// AVKit Picture-in-Picture adapter built on `displayLayer` (re-targeted
    /// by `rebuildDisplayLayer()`). The system PiP window shows the SAME layer
    /// the stream window paints into, so the two are mutually exclusive:
    /// entering PiP hides this window, returning to this window stops PiP.
    /// App-wide (PictureInPictureStage), so PiP can outlive a stream when
    /// switching PCs; this window drives it only while it owns the stage.
    var pictureInPicture: StreamPictureInPicture { PictureInPictureStage.shared.pictureInPicture }
    /// The layer (and invisible window) Apple's PiP shows - not this window's.
    var pipSource: PiPSource { PictureInPictureStage.shared.source }
    /// Keeps the picture whole inside Apple's PiP window.
    var pipFitter: PiPPanelFitter { PictureInPictureStage.shared.fitter }
    /// The PiP layer, for the decoder to feed alongside the stream's own.
    public var pipLayer: AVSampleBufferDisplayLayer { pipSource.layer }
    /// True from `hideStreamWindow()` (orderOut) until `reengageForeground()`.
    var isBackgrounded = false
    /// True while the system PiP window is up (AVKit didStart → didStop).
    public private(set) var isPictureInPictureActive = false
    /// True between our `start()` and AVKit's didStart / failedToStart, so
    /// present suppression is NOT engaged for the ~100ms the PiP window takes
    /// to come up (it would cost a drain + an IDR resync for nothing).
    var pictureInPicturePending = false
    /// The PiP window's play/pause control. Paused maps onto present
    /// suppression (freeze on the newest frame, decode gates after 2s).
    var pictureInPicturePaused = false
    /// Last value handed to `onPresentSuppressionChanged`, so only real edges
    /// reach the decoder (its transition work is not free).
    var lastEmittedPresentSuppressed = false
    /// `GCController.shouldMonitorBackgroundEvents` before we flipped it on
    /// for PiP; restored on PiP stop / close. nil = we never touched it.
    var savedControllerBackgroundFlag: Bool?
    /// The stream is hidden for Picture in Picture (PiP up or starting): the
    /// stream window's own key/resign transitions are meaningless then, and
    /// returns come through the explicit PiP / menu paths.
    var pipSourceMode = false
    /// The PiP return found another app full screen in front.
    var returnedOverFullScreenApp = false
    /// AppModel's "Switch PC" is ending this stream for another: the closing
    /// window leaves the app where it is (no launcher hand-off).
    static var switchingHosts = false
    /// Captured at close(): whether finishClose brings the launcher forward.
    var handsOffToLauncher = true
    /// Open this stream straight into Picture in Picture (set before show()).
    public var launchesInPictureInPicture = false
    /// From show() until the first frames start PiP: the window has never been
    /// shown and must not be - no activation, no cursor hide, no presentation
    /// options - so the app the user is in stays in front.
    var launchingIntoPiP = false
    /// The PiP start in flight began as a launch: it grows from where the PiP
    /// window last was, and if it fails the window is shown instead.
    var pipStartIsLaunch = false
    /// The window's level + collection behaviour from before a window-mode
    /// return's temporary floating shape (see `returnFromPictureInPicture`).
    var savedShapeBeforePiP: (level: NSWindow.Level, behavior: NSWindow.CollectionBehavior)?
    /// Keeps the PiP picture from staying frozen after a Stage Manager or
    /// Mission Control animation during a screen recording (`PiPKeepAlive`).
    var pipKeepAlive: PiPKeepAlive?
    /// PiP window came up / went away. The session owner rebinds the frame
    /// pacer (screen link vs view link) and tells the launcher UI.
    public var onPictureInPictureChanged: (@MainActor (Bool) -> Void)?
    /// The system PiP panel was located (non-nil, on didStart) or PiP ended
    /// (nil). The session owner points the input forwarder's pointer mirror
    /// at it so the Mac pointer over the PiP window drives the host pointer.
    public var onPictureInPicturePanelChanged: (@MainActor (NSWindow?) -> Void)?
    /// The decoder's "nobody is looking at the layer" signal:
    /// backgrounded AND not (in / entering) PiP, OR paused from the PiP
    /// controls. Replaces the decoder's former use of `onBackgroundedChanged`,
    /// which conflated "window hidden" with "nothing presents".
    public var onPresentSuppressionChanged: (@MainActor (Bool) -> Void)?
    /// Setter for the PiP-active flag scoped to the window's own files.
    func setPictureInPictureActive(_ active: Bool) { isPictureInPictureActive = active }

    /// Called when the stream window moves to a different display (or its
    /// backing display's properties change - refresh rate, wake from sleep).
    /// The session owner wires this to `VideoDecoder.pacingScreenDidChange()`
    /// so the FramePacer rebinds its CADisplayLink to the new screen's true
    /// vsync cadence; presenting on a stale link after a 60↔120Hz display swap
    /// would pace to the wrong refresh.
    public var onScreenChanged: (@MainActor () -> Void)?

    /// Set by `show()` and cleared by the first-frame fade-in. Guards
    /// the fade-in animation against being re-fired on subsequent first-
    /// frame events (e.g. a mid-stream resolution change that flushes the
    /// decoder and produces a new "first" frame - the window is already
    /// visible, no fade needed).
    var awaitingFirstFrameFadeIn = false

    /// True from the start of a return from Picture in Picture until AVKit has
    /// reported the stop and the window has been re-asserted key.
    var pipReturnInFlight = false

    /// Called once the window is on screen and key. InputForwarder uses this
    /// to install its StreamInputView as the window's first responder.
    ///
    /// Fired after the window comes up (next runloop, and again from the
    /// 1.5 s key backstop) and after every full-screen transition, which
    /// resets the responder chain. A window can be on screen and still not
    /// key if the app wasn't active at makeKeyAndOrderFront; without the
    /// re-install the responder chain routes nowhere and keyDown is lost.
    public var onDidBecomeReadyForInput: (@MainActor () -> Void)?

    public init() {
        // Pick the screen the user is *currently* on at construction time.
        // StreamSession constructs us right when the user clicks "Stream",
        // so NSScreen.main reflects the display the launcher window was on
        // - i.e. the display the user is actually looking at. If they later
        // drag a multi-monitor setup around mid-stream, we deliberately do
        // not follow; the stream picks the screen once and stays there for
        // the duration of the session.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            // A Mac with zero attached displays cannot host a stream window;
            // there is no frame to size to and no NSScreen to bind the window's
            // backing display. This mirrors the prior force-unwrap's crash-on-nil
            // contract (init must hand back a fully-formed window), but spells out
            // why rather than trapping with a bare `!`.
            preconditionFailure("StreamWindow.init: no attached display to host the stream window")
        }
        // A real titled window: closable (the red button ends the stream),
        // miniaturizable, resizable (aspect-locked in show()).
        let window = KeyableWindow(
            contentRect: screen.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isReleasedWhenClosed = false

        // `.fullScreenPrimary`: the green button and ⌃⌘F take the window into
        // its own full-screen Space. HDR doesn't depend on it - EDR follows
        // the layer's PQ content + wantsExtendedDynamicRangeContent.
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = .black
        window.acceptsMouseMovedEvents = true
        window.hidesOnDeactivate = false

        // Screen capture is ALLOWED (`.readOnly`). This used to be `.none`,
        // which hides the window from ScreenCaptureKit, screencapture(1),
        // Cmd-Shift-5 and screen sharing - the Netflix / Apple TV+ posture,
        // inherited from glimmer. But the stream is the user's own game, not
        // protected video, and the system Picture in Picture window mirrors
        // THIS window's layer: with `.none`, the PiP picture stopped as soon
        // as a screen recording started (reported on macOS 27.2). Recording
        // your own stream on the Mac is a normal thing to want, and nothing
        // here is secret from the person at the keyboard.
        window.sharingType = .readOnly

        let view = DisplayContainerView(frame: screen.frame)

        // ---- AVSampleBufferDisplayLayer setup (parallels moonlight-qt's
        // vt_avsamplelayer.mm - `m_StreamView.layer = m_DisplayLayer;
        // m_StreamView.wantsLayer = YES;`).
        //
        // CRITICAL for HDR: we make the AVSampleBufferDisplayLayer the
        // view's ROOT layer (set BEFORE wantsLayer = true), not a sublayer
        // of a default backing layer. When a display layer is a sublayer of
        // a regular sRGB CALayer, the OS's compositor flattens the EDR
        // signal at the parent layer boundary, dropping HDR back to SDR
        // before it reaches the panel. The "root layer" form keeps the EDR
        // path direct from the layer to the window surface.
        //
        // moonlight-qt sets `videoGravity = AVLayerVideoGravityResizeAspect`
        // - letterboxes rather than crops to fill. Matches what we want for
        // streaming a 16:9 host onto a 16:9 panel (the common case) while
        // gracefully handling odd aspect ratios on multi-monitor setups.
        // It also marks the layer opaque so the compositor can skip blending
        // it against whatever's underneath.
        let layer = StreamWindow.makeDisplayLayer(frame: view.bounds)
        view.layer = layer
        view.wantsLayer = true
        window.contentView = view

        // Stats overlay - sublayer of the display layer, positioned in the
        // top-left with a fixed inset. We attach it as a sublayer rather than
        // a sibling because AVSampleBufferDisplayLayer is the view's root
        // layer (a precondition for HDR-correct compositing - see the long
        // comment near `view.layer = layer` above). CALayer's sublayer
        // contract lets us stack arbitrary content on top, and the OS
        // composites the overlay's sRGB text against the layer's HDR
        // contents correctly.
        //
        // Created hidden - StreamSession's overlay timer toggles
        // `isHidden` from `VideoDecoder.statsOverlayEnabled` and pushes
        // text updates at 4 Hz (the FPS rows stay on a ~1s average; the
        // latency rows refresh live each tick).
        let overlay = StatsOverlayLayer()
        overlay.attach(to: layer)
        overlay.setVisible(false)

        // Transient signal pills (sibling sublayers of the display layer, above
        // the stats panel). Created hidden; the session drives them on edges.
        let reconnect = StreamBannerLayer(
            anchor: .topCenter, accent: NSColor.systemOrange.cgColor)
        reconnect.attach(to: layer)
        let network = StreamBannerLayer(
            anchor: .bottomCenter, accent: NSColor.systemYellow.cgColor)
        network.attach(to: layer)
        // Stacked above the network pill (both bottomCenter) so the two can't
        // render on top of each other: 28 inset + 34 height + 10 gap = 72.
        let leaveHint = StreamBannerLayer(
            anchor: .bottomCenter, accent: NSColor.white.cgColor, inset: 72)
        leaveHint.attach(to: layer)
        // One rung higher again (72 + 34 + 10 = 116) so the pointer hint can
        // share the corner with both of the pills below it.
        let captureHint = StreamBannerLayer(
            anchor: .bottomCenter, accent: NSColor.white.cgColor, inset: 116)
        captureHint.attach(to: layer)

        // The red button and full-screen failures (StreamWindow+Views).
        let delegate = StreamWindowDelegate()
        window.delegate = delegate

        self.window = window
        self.displayLayer = layer
        self.statsOverlay = overlay
        self.reconnectBanner = reconnect
        self.networkBanner = network
        self.leaveHintBanner = leaveHint
        self.captureHintBanner = captureHint
        self.displayView = view
        self.streamDelegate = delegate
        // PiP handlers go in when this window claims or adopts the stage
        // (StreamWindow+PictureInPicture.swift), never before: a switch may
        // still be holding the previous stream's PiP.
        // The red button / Cmd-W route through the delegate to the session's
        // stop() (StreamWindow+Windowed.swift). Wired after full
        // initialization because it captures self.
        delegate.onCloseRequested = { [weak self] in self?.handleUserCloseRequest() }
    }

    /// Strong ref so the window delegate isn't deallocated mid-stream
    /// (NSWindow.delegate is `weak`).
    let streamDelegate: StreamWindowDelegate

    /// Build a fresh AVSampleBufferDisplayLayer configured exactly as the
    /// HDR-correct root-layer path requires (see the long comment at the top of
    /// this file). Factored out so `init` and `rebuildDisplayLayer()` produce
    /// byte-for-byte identical layers - the rebuild must not subtly differ from
    /// the original or HDR engagement could regress after a recovery.
    private static func makeDisplayLayer(frame: CGRect) -> AVSampleBufferDisplayLayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = frame
        layer.videoGravity = .resizeAspect
        layer.isOpaque = true
        return layer
    }

    /// Rebuild the display layer from scratch and swap it in as the view's root
    /// layer. The last-resort present-path self-heal: the
    /// AVSampleBufferVideoRenderer can latch `.status == .failed` (a 4K240 HDR panel
    /// 4K240 HDR hard-freeze) and stay failed after a bare `flush()` - a
    /// hard-failed renderer only clears with a fresh layer. We create a new
    /// AVSampleBufferDisplayLayer, re-attach the stats overlay sublayer, swap it
    /// in as the view's ROOT layer (preserving the EDR-direct compositing
    /// contract), and return it so the caller can re-point the decoder at it.
    ///
    /// Runs on the main actor (the only place that touches AppKit layers). The
    /// decoder snapshots `displayLayer` into a local before each enqueue, so a
    /// concurrent present on the pacer/decode queue keeps operating on the OLD
    /// layer until it picks up the new reference - race-safe by construction.
    @discardableResult
    public func rebuildDisplayLayer() -> AVSampleBufferDisplayLayer {
        let view = displayView
        let fresh = StreamWindow.makeDisplayLayer(frame: view.bounds)
        // Re-attach the stats overlay + signal pills as sublayers of the NEW
        // root layer before the swap, so they keep compositing above the video.
        // attach() re-parents (addSublayer removes from any prior superlayer).
        statsOverlay.attach(to: fresh)
        reconnectBanner.attach(to: fresh)
        networkBanner.attach(to: fresh)
        leaveHintBanner.attach(to: fresh)
        captureHintBanner.attach(to: fresh)
        // Swap as the view's root layer - same construction as init so the
        // EDR-direct path is preserved (root layer, not a sublayer of a backing
        // layer). wantsLayer stays true.
        view.layer = fresh
        view.wantsLayer = true
        self.displayLayer = fresh
        // PiP shows its own layer (PiPSource), so it carries on untouched.
        log.notice("Rebuilt AVSampleBufferDisplayLayer (present-path self-heal)")
        return fresh
    }
}
