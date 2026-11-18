//
//  StreamPictureInPicture.swift
//
//  Thin adapter over AVKit's Picture in Picture for the stream's
//  AVSampleBufferDisplayLayer. The system PiP window (the one Safari /
//  QuickTime use) is fed by the SAME layer the fullscreen stream window
//  paints into: `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:)`
//  takes over the layer's renderer output while PiP is active and hands it
//  back on stop. Nothing in the decode / pacing path changes - frames keep
//  landing on `layer.sampleBufferRenderer` exactly as before.
//
//  Verified on macOS 26 (see docs/design/2026-09-10-picture-in-picture-design.md):
//  PiP starts from a borderless window's root layer, while the app is NOT
//  active, and even while the source window is already orderOut'd; it keeps
//  rendering after the window is hidden; no `controlTimebase` is needed for
//  the host-PTS sample buffers we enqueue.
//
//  This class knows nothing about windows, decoders, or settings. It owns
//  the controller, is its delegate, and surfaces edges as MainActor closures:
//    onDidStart / onDidStop         - the PiP window came up / went away
//    onRestoreRequested             - the user hit the "return" button (or a
//                                     programmatic stop asked for restore)
//    onPauseChanged                 - the PiP window's play/pause control
//    onFailedToStart                - AVKit refused (another app owns PiP, ...)
//

import AVFoundation
import AVKit
import CoreMedia
import Foundation
import ObjectiveC
import os

@MainActor
public final class StreamPictureInPicture: NSObject {
    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.PiP")

    private var controller: AVPictureInPictureController?
    private var contentSource: AVPictureInPictureController.ContentSource?
    /// The layer the controller is currently built on. Kept so `retarget` can
    /// no-op when handed the same layer twice.
    private weak var layer: AVSampleBufferDisplayLayer?

    /// Set for the duration of a programmatic `stop()` so the restore
    /// callback AVKit fires on every stop (user-initiated OR ours) is only
    /// surfaced as `onRestoreRequested` when the USER asked to come back.
    private var stoppingProgrammatically = false
    /// Latched by the restore callback; read in didStop to tell "return to
    /// app" (restore requested) from "closed with ×" (no restore) apart.
    private var restoreRequested = false
    /// True from willStop (AVKit's, or our own `stop()`) until didStop, so a
    /// second stop request during the ~0.5s dismiss animation is a no-op.
    private var isStopping = false
    /// Armed by `stop()`: AVKit can silently ignore `stopPictureInPicture()`,
    /// and a latched `isStopping` with no willStop/didStop ever coming would
    /// make every later stop a no-op forever - the PiP window then outlives
    /// the stream window's return and mirrors the fullscreen source as a 1:1
    /// crop. If nothing lands within `stopAckTimeout`, ask again, and after
    /// `stopAttempts` unlatch so the state machine stays honest (the user's
    /// own × / return still work). The one KNOWN way to provoke an ignored
    /// stop - asking from inside AVKit's didStart callback - wedges the
    /// controller for retries too (measured: 3 asks over 1.5s, all dropped),
    /// which is why the owner defers that particular stop instead of relying
    /// on this; the watchdog is the backstop for whatever else AVKit drops.
    private var stopWatchdog: DispatchWorkItem?
    /// Set by `reset()`: if AVKit ignores the stop, rebuild the controller.
    private var rebuildIfStopIgnored = false
    private static let stopAckTimeout: TimeInterval = 0.75
    private static let stopAttempts = 3

    /// PiP's play/pause state as the PiP controls last set it. Read by
    /// AVKit's `pictureInPictureControllerIsPlaybackPaused` off the main
    /// thread, so it lives behind a lock rather than on the actor.
    private let pausedState = OSAllocatedUnfairLock(initialState: false)

    public var onDidStart: (@MainActor () -> Void)?
    /// `restoreRequested` is true when the user hit the return-to-app button
    /// (the window should come back), false for the × close button (the
    /// stream stays hidden).
    public var onDidStop: (@MainActor (_ restoreRequested: Bool) -> Void)?
    /// The user asked to come back (the PiP window's return control). Call
    /// `ready` once the window is on screen where the user is looking: AVKit
    /// waits for it before flying the picture back, so the animation lands
    /// in a visible window. A 2 s backstop answers if the owner never does.
    public var onRestoreRequested: (@MainActor (_ ready: @escaping @MainActor () -> Void) -> Void)?
    public var onPauseChanged: (@MainActor (Bool) -> Void)?
    public var onFailedToStart: (@MainActor (Error) -> Void)?

    public private(set) var isActive = false

    /// Up, starting, or still animating closed: there is one PiP controller,
    /// so a new start must wait for this to clear (a Switch PC in PiP closes
    /// the old stream's PiP, then opens the next one's).
    public var isInUse: Bool {
        isActive || isStopping || controller?.isPictureInPictureActive == true
    }

    /// One line of controller + adapter state for the env-gated debug probe
    /// (`--debug-pip-probe`); never read on a normal launch.
    public var debugState: String {
        let ctl = controller
        return "ctl.active=\(ctl?.isPictureInPictureActive ?? false) ctl.possible=\(ctl?.isPictureInPicturePossible ?? false) "
            + "ctl.suspended=\(ctl?.isPictureInPictureSuspended ?? false) isActive=\(isActive) isStopping=\(isStopping) "
            + "stoppingProgrammatically=\(stoppingProgrammatically) restoreRequested=\(restoreRequested)"
    }

    public init(layer: AVSampleBufferDisplayLayer) {
        super.init()
        build(on: layer)
    }

    /// Whether AVKit would let us start right now. False when the system's
    /// single PiP slot is taken by another app, or PiP is unsupported.
    public var isPossible: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
            && (controller?.isPictureInPicturePossible ?? false)
    }

    /// Point the controller at a fresh layer (the renderer hard-fail self-heal
    /// rebuilds the display layer). The old controller's PiP window collapses
    /// with its old layer. Returns whether PiP was active, so the owner can
    /// reconcile its own state - this deliberately does NOT auto-restart PiP:
    /// the system's single PiP slot is still held by the dismissing old window,
    /// so an immediate `start()` would silently fail the `isPossible` guard and
    /// strand the owner's `isPictureInPictureActive` flag true forever (no
    /// callback ever comes because `build` nils the old delegate).
    @discardableResult
    public func retarget(layer newLayer: AVSampleBufferDisplayLayer) -> Bool {
        guard newLayer !== layer else { return false }
        let wasActive = isActive
        if wasActive {
            stoppingProgrammatically = true
            controller?.stopPictureInPicture()
            stoppingProgrammatically = false
            isActive = false
            isStopping = false
            disarmStopWatchdog()
        }
        build(on: newLayer)
        return wasActive
    }

    public func start() {
        guard let controller else { return }
        guard !controller.isPictureInPictureActive else { return }
        guard isPossible else {
            log.notice("Picture in Picture not possible right now (another app may own it) - not starting")
            return
        }
        restoreRequested = false
        pausedState.withLock { $0 = false }
        log.info("Starting Picture in Picture")
        controller.startPictureInPicture()
    }

    public func stop() {
        guard let controller, controller.isPictureInPictureActive, !isStopping else { return }
        log.info("Stopping Picture in Picture")
        stoppingProgrammatically = true
        isStopping = true
        controller.stopPictureInPicture()
        armStopWatchdog(attempt: 1)
    }

    private func armStopWatchdog(attempt: Int) {
        stopWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stopWatchdog = nil
            // Acknowledged (willStop/didStop cleared the latch), or PiP is gone
            // by some other route - nothing to do.
            guard self.isStopping, let controller = self.controller,
                  controller.isPictureInPictureActive else { return }
            if attempt >= Self.stopAttempts {
                self.log.error("Picture in Picture stop ignored by AVKit \(attempt) times - giving up; state unlatched")
                self.isStopping = false
                self.stoppingProgrammatically = false
                // The stream that owned it is gone (`reset`): the controller
                // is reused by the next stream, and one AVKit still counts as
                // active would make its start() a no-op. Start over with a
                // fresh controller; the stuck PiP window goes with the old one.
                if self.rebuildIfStopIgnored, let layer = self.layer {
                    self.rebuildIfStopIgnored = false
                    self.log.error("Rebuilding the Picture in Picture controller for the next stream")
                    controller.delegate = nil
                    self.isActive = false
                    self.build(on: layer)
                }
                return
            }
            self.log.error("Picture in Picture stop not acknowledged within \(Self.stopAckTimeout)s - asking again (attempt \(attempt + 1))")
            controller.stopPictureInPicture()
            self.armStopWatchdog(attempt: attempt + 1)
        }
        stopWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopAckTimeout, execute: item)
    }

    private func disarmStopWatchdog() {
        stopWatchdog?.cancel()
        stopWatchdog = nil
    }

    /// A stream let go of PiP (PictureInPictureStage): close it if it is up,
    /// the way its × does, and drop the stream's handlers, keeping the
    /// controller for the next stream.
    public func reset() {
        onDidStart = nil; onDidStop = nil; onRestoreRequested = nil
        onPauseChanged = nil; onFailedToStart = nil
        if let controller, controller.isPictureInPictureActive {
            rebuildIfStopIgnored = true
            if !isStopping {
                stoppingProgrammatically = true
                isStopping = true
                // Armed first: AVKit answers willStop inside the call, and
                // that is what stands the watchdog down. (Armed after, it
                // stayed up until didStop, ~0.47 s later - a slow close would
                // have had it ask again, the public way, in mid-fade.)
                armStopWatchdog(attempt: 1)
                close(controller)
            }
        }
        pausedState.withLock { $0 = false }
    }

    // MARK: - Closing as the × does

    /// What the PiP window's × runs. The controls are drawn by macOS's
    /// PIPAgent, which messages our process on a click:
    ///   -[PIPViewController _pipActionClose]
    ///   -[AVPictureInPicturePlatformAdapter pipActionClose:]
    ///   -[AVPictureInPictureController _stopPictureInPictureAndRestoreUserInterface:NO]
    /// (call stack of a real click, 2026-11-17, macOS 27.0; the method is also
    /// on 27.2.1). The public `stopPictureInPicture()` is the same method with
    /// YES - "return to app", which flies the picture back to the source layer.
    /// With NO the agent shrinks and fades the PiP where it is, about 0.16 s;
    /// recorded next to a real click, the two match frame for frame.
    private static let closeSelector = NSSelectorFromString("_stopPictureInPictureAndRestoreUserInterface:")

    /// Whether this macOS still has that method, taking one BOOL. Private API:
    /// without it PiP stops the public way (`PictureInPictureStage.close`
    /// makes that an instant close).
    static var canCloseAsTheCloseButtonDoes: Bool {
        guard let method = class_getInstanceMethod(AVPictureInPictureController.self, closeSelector),
              method_getNumberOfArguments(method) == 3,
              let argument = method_copyArgumentType(method, 2) else { return false }
        defer { free(argument) }
        let type = String(cString: argument)
        return type == "B" || type == "c"
    }

    // MARK: - No pause button

    /// AVKit's private `controlsStyle`, as macOS 27.0 draws each value
    /// (screenshots of the PiP window with the pointer over it, 2026-11-17):
    /// 0 - the default, a pause button in the middle; 1 - a microphone mute
    /// button (video calls); 2 - no transport at all, only × and "return to
    /// app", which both work as before. Set before or during PiP; it stays
    /// across starts.
    private static let controlsStyleSelector = NSSelectorFromString("setControlsStyle:")
    private static let controlsStyleWithoutTransport = 2

    /// Whether this macOS still has that setter, taking one integer. Private
    /// API: without it the pause button shows, and pausing stays refused
    /// (`pictureInPictureController(_:setPlaying:)`).
    static var canHidePlaybackControls: Bool {
        guard let method = class_getInstanceMethod(AVPictureInPictureController.self, controlsStyleSelector),
              method_getNumberOfArguments(method) == 3,
              let argument = method_copyArgumentType(method, 2) else { return false }
        defer { free(argument) }
        return String(cString: argument) == "q"
    }

    /// A live game has nothing to pause: take the button away.
    private func hidePlaybackControls(of controller: AVPictureInPictureController) {
        guard Self.canHidePlaybackControls else {
            log.notice("Picture in Picture: no controls style on this macOS - the pause button stays")
            return
        }
        typealias SetStyle = @convention(c) (AnyObject, Selector, Int) -> Void
        let setStyle = unsafeBitCast(controller.method(for: Self.controlsStyleSelector), to: SetStyle.self)
        setStyle(controller, Self.controlsStyleSelector, Self.controlsStyleWithoutTransport)
    }

    // MARK: - No return button

    /// Stands in for AVKit's adapter while PiP is up (`hideReturnButton`).
    /// The system's PiP controller holds its delegate weakly, and without one
    /// a × click never reaches AVKit - so this stays until the next start
    /// replaces it.
    private var delegateStandIn: PiPDelegateStandIn?

    private static let platformAdapterSelector = NSSelectorFromString("platformAdapter")
    private static let systemControllerSelector = NSSelectorFromString("systemPIPViewController")
    private static let delegateSelector = NSSelectorFromString("delegate")
    private static let setDelegateSelector = NSSelectorFromString("setDelegate:")

    /// Whether this macOS still has the private pieces `hideReturnButton`
    /// goes through. Without them the button shows, and works, as before.
    static var canHideReturnButton: Bool {
        guard let adapter = NSClassFromString("AVPictureInPicturePlatformAdapter"),
              let system = NSClassFromString("PIPViewController") else { return false }
        return AVPictureInPictureController.instancesRespond(to: platformAdapterSelector)
            && adapter.instancesRespond(to: systemControllerSelector)
            && adapter.instancesRespond(to: PiPDelegateStandIn.returnAction)
            && system.instancesRespond(to: delegateSelector)
            && system.instancesRespond(to: setDelegateSelector)
    }

    /// Take "return to app" off the PiP window; the stream window comes back
    /// from the menu bar or the PiP shortcut instead. macOS's PIPAgent draws
    /// the button only for a delegate that handles `pipActionRestore:`, and
    /// tells the agent so the moment the delegate is set (screenshots,
    /// 2026-11-17, macOS 27.0). Every PiP start makes a new system controller
    /// with AVKit's adapter as its delegate, so this runs on each start.
    ///
    /// The × stays: the agent draws it in its own window whatever the
    /// delegate, control style or content type says (all tried).
    private func hideReturnButton() {
        guard Self.canHideReturnButton, let controller,
              let adapter = controller.perform(Self.platformAdapterSelector)?.takeUnretainedValue() as? NSObject,
              let system = adapter.perform(Self.systemControllerSelector)?.takeUnretainedValue() as? NSObject,
              let current = system.perform(Self.delegateSelector)?.takeUnretainedValue() as? NSObject,
              !(current is PiPDelegateStandIn) else { return }
        let standIn = PiPDelegateStandIn(adapter: current)
        delegateStandIn = standIn
        _ = system.perform(Self.setDelegateSelector, with: standIn)
    }

    private func close(_ controller: AVPictureInPictureController) {
        guard Self.canCloseAsTheCloseButtonDoes else {
            log.notice("Picture in Picture: no × close on this macOS - stopping the public way")
            controller.stopPictureInPicture()
            return
        }
        typealias Close = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        let close = unsafeBitCast(controller.method(for: Self.closeSelector), to: Close.self)
        log.info("Closing Picture in Picture as its × does")
        close(controller, Self.closeSelector, false)
    }

    /// Drop the controller without any callbacks - session teardown.
    public func invalidate() {
        onDidStart = nil; onDidStop = nil; onRestoreRequested = nil
        onPauseChanged = nil; onFailedToStart = nil
        if controller?.isPictureInPictureActive == true {
            stoppingProgrammatically = true
            controller?.stopPictureInPicture()
        }
        controller?.delegate = nil
        controller = nil
        contentSource = nil
        isActive = false
        isStopping = false
        disarmStopWatchdog()
    }

    private func build(on newLayer: AVSampleBufferDisplayLayer) {
        controller?.delegate = nil
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: newLayer, playbackDelegate: self)
        let ctl = AVPictureInPictureController(contentSource: source)
        ctl.delegate = self
        // A live stream has no timeline to scrub - hide the skip affordances.
        ctl.requiresLinearPlayback = true
        hidePlaybackControls(of: ctl)
        contentSource = source
        controller = ctl
        layer = newLayer
    }

    /// Run `body` on the main actor: inline when AVKit calls us on the main
    /// thread (the delegate contract), otherwise hop.
    private nonisolated func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { body() }
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension StreamPictureInPicture: AVPictureInPictureControllerDelegate {
    public nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        // As early as the system controller exists (didStart asks again).
        onMain { [self] in hideReturnButton() }
    }

    public nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        onMain { [self] in
            isActive = true
            hideReturnButton()
            log.info("Picture in Picture started")
            onDidStart?()
        }
    }

    public nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        onMain { [self] in
            isActive = false
            log.error("Picture in Picture failed to start: \(error.localizedDescription, privacy: .public)")
            onFailedToStart?(error)
        }
    }

    public nonisolated func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        onMain { [self] in
            isStopping = true
            disarmStopWatchdog()
        }
    }

    public nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // The handler is not Sendable; it is only ever called on main.
        let box = RestoreCompletion(completionHandler)
        onMain { [self] in
            isStopping = true
            disarmStopWatchdog()
            // AVKit asks for restore on EVERY stop, including ours. Only a stop
            // we did not initiate is the user asking to come back.
            guard !stoppingProgrammatically, let onRestoreRequested else {
                box.finish()
                return
            }
            restoreRequested = true
            onRestoreRequested { box.finish() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { box.finish() }
        }
    }

    /// AVKit's restore completion, answered exactly once.
    private final class RestoreCompletion: @unchecked Sendable {
        private var handler: ((Bool) -> Void)?
        init(_ handler: @escaping (Bool) -> Void) { self.handler = handler }
        func finish() {
            guard let handler else { return }
            self.handler = nil
            handler(true)
        }
    }

    public nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        onMain { [self] in
            let restore = restoreRequested
            rebuildIfStopIgnored = false
            isActive = false
            isStopping = false
            restoreRequested = false
            stoppingProgrammatically = false
            disarmStopWatchdog()
            log.info("Picture in Picture stopped (restoreRequested=\(restore, privacy: .public))")
            onDidStop?(restore)
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension StreamPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    /// Pause is REFUSED. The pause button is hidden (`hidePlaybackControls`),
    /// but that is private API, and a pause can come from elsewhere (the
    /// system's media controls). A live game has nothing to pause: the host
    /// keeps playing, so "pausing" only freezes the mirror and then jumps on
    /// resume. Instead of honouring it we stay playing and immediately tell
    /// AVKit so, which snaps the button back.
    public nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool
    ) {
        guard !playing else { return }
        pausedState.withLock { $0 = false }
        onMain { [self] in
            self.controller?.invalidatePlaybackState()
            self.log.notice("Picture in Picture pause ignored - a live stream has nothing to pause")
        }
    }

    public nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        // Live: no seekable timeline.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    public nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        pausedState.withLock { $0 }
    }

    public nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // The PiP window resized; the renderer scales the sample buffers
        // itself, nothing for us to do.
    }

    public nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void
    ) {
        // Live stream - nothing to skip within.
        completionHandler()
    }

    public nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }
}

// MARK: - The system PiP controller's delegate, minus "return to app"

/// AVKit's platform adapter with one action taken away. macOS's PiP window
/// shows a button only for an action its delegate handles; this answers "no"
/// for `pipActionRestore:` and passes everything else (× above all) straight
/// to the adapter.
final class PiPDelegateStandIn: NSObject {
    static let returnAction = NSSelectorFromString("pipActionRestore:")

    private let adapter: NSObject

    init(adapter: NSObject) { self.adapter = adapter }

    override func responds(to selector: Selector!) -> Bool {
        guard let selector, selector != Self.returnAction else { return false }
        return adapter.responds(to: selector)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { adapter }

    override func conforms(to proto: Protocol) -> Bool { adapter.conforms(to: proto) }
}
