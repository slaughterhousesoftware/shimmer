//
//  PictureInPictureStage.swift
//
//  Apple's Picture in Picture, owned by the app rather than by one stream, so
//  it can outlive a stream: switching PCs in PiP keeps the same PiP window on
//  screen - the old stream's last frame holds while the next one connects,
//  and the next one's first frame replaces it in place. No close, no reopen,
//  no animation, wherever the user put the window.
//
//  One stage, one owner at a time. A stream window claims it when it starts
//  PiP (`claim`), or adopts it mid-switch (`adopt`); its handlers are the only
//  ones installed. When a switch is pending (`holdForSwitch`) the owning
//  window's teardown leaves PiP up (`hold`) instead of stopping it, and the
//  stage answers PiP's own controls itself until the next stream adopts it:
//
//      owned by A ──A closes, switch pending──▶ holding ──B's first frames──▶ owned by B
//                                                  │
//                                                  └── × / return / timeout / B failed ──▶ stopped
//
//  The cut-over needs one thing (measured 2026-11-16 with a bare harness,
//  every mix of size, SDR / HDR10 and timestamp base, 3 s and 15 s gaps): the
//  layer's renderer flushed, keeping its image, before the new stream's
//  frames. Without it a stream whose timestamps run below the old one's never
//  shows - the PiP stays on the old frame.
//

import AppKit
import AVFoundation
import GameController

@MainActor
final class PictureInPictureStage {
    static let shared = PictureInPictureStage()

    /// The layer (and invisible window) Apple's PiP shows.
    let source = PiPSource()
    /// AVKit's controller, built once on `source.layer` and reused by every stream.
    let pictureInPicture: StreamPictureInPicture
    /// Keeps the picture whole inside Apple's PiP window.
    let fitter = PiPPanelFitter()

    /// The stream window the stage serves.
    private(set) weak var owner: StreamWindow?
    /// A switch asked the owner's teardown to leave PiP up.
    private(set) var holdRequested = false
    /// PiP is up with no stream: the last frame holds until the next stream
    /// adopts it.
    private(set) var isHolding = false
    /// The PiP window ended while holding: `restoreRequested` is true for its
    /// return button, false for × (and for a hold that timed out or failed).
    var onHoldEnded: ((_ restoreRequested: Bool) -> Void)?

    private var heldKeepAlive: PiPKeepAlive?
    private var heldControllerBackgroundFlag: Bool?
    private var holdGeneration = 0
    /// Longest a PiP may hold a frozen frame: a PS5 waking from rest takes
    /// about 15 s; anything longer has failed without saying so.
    static let holdTimeout: TimeInterval = 45

    private init() {
        pictureInPicture = StreamPictureInPicture(layer: source.layer)
    }

    func isOwned(by window: StreamWindow) -> Bool { owner === window }

    /// `window` starts PiP on the stage; its handlers are installed by the caller.
    func claim(by window: StreamWindow) {
        owner = window
    }

    /// `window` closed or gave PiP up without a switch.
    func release(by window: StreamWindow) {
        guard owner === window else { return }
        owner = nil
    }

    /// The next teardown of the owner, if it is in PiP, leaves PiP up.
    func holdForSwitch() {
        holdRequested = true
    }

    /// Drop a hold request that never turned into a hold.
    func cancelHoldRequest() {
        holdRequested = false
    }

    /// Called by the owner's teardown. True when PiP was left up (holding);
    /// the window then must not touch the stage again.
    func holdIfRequested(by window: StreamWindow, keepAlive: PiPKeepAlive?, controllerBackgroundFlag: Bool?) -> Bool {
        guard owner === window, holdRequested, pictureInPicture.isActive else { return false }
        holdRequested = false
        owner = nil
        isHolding = true
        heldKeepAlive = keepAlive
        heldControllerBackgroundFlag = controllerBackgroundFlag
        installHoldHandlers()
        holdGeneration &+= 1
        let generation = holdGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isHolding, self.holdGeneration == generation else { return }
                Diag.warn("PiP switch: no new stream after \(Int(Self.holdTimeout)) s - closing Picture in Picture", "Stream.PiP")
                self.endHold(restoreRequested: false)
            }
        }
        Diag.info("PiP switch: holding the last frame while the next stream connects", "Stream.PiP")
        return true
    }

    /// The next stream's window is built: make the layer ready for its frames.
    /// Keeps the held picture on screen until they arrive.
    func prepareForNextStream() {
        guard isHolding else { return }
        source.layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
    }

    /// `window` takes over the held PiP. Returns what it inherits.
    func adopt(by window: StreamWindow) -> (keepAlive: PiPKeepAlive?, controllerBackgroundFlag: Bool?)? {
        guard isHolding else { return nil }
        isHolding = false
        holdGeneration &+= 1
        owner = window
        let inherited = (heldKeepAlive, heldControllerBackgroundFlag)
        heldKeepAlive = nil
        heldControllerBackgroundFlag = nil
        Diag.info("PiP switch: the new stream took over Picture in Picture", "Stream.PiP")
        return inherited
    }

    /// Stop a held PiP: the switch was cancelled, failed or timed out, or the
    /// user asked for the stream window. `notify` tells `onHoldEnded`.
    func endHold(restoreRequested: Bool, notify: Bool = true) {
        guard isHolding else { return }
        isHolding = false
        holdGeneration &+= 1
        pictureInPicture.reset()
        finishHold()
        if notify { onHoldEnded?(restoreRequested) }
    }

    private func finishHold() {
        heldKeepAlive?.stop()
        heldKeepAlive = nil
        if let flag = heldControllerBackgroundFlag {
            GCController.shouldMonitorBackgroundEvents = flag
            heldControllerBackgroundFlag = nil
        }
        fitter.detach()
        source.hide()
        source.layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    /// While holding, PiP's own controls answer to the stage.
    private func installHoldHandlers() {
        fitter.onPanelChanged = { [weak self] panel in
            guard let self, panel == nil else { return }
            self.heldKeepAlive?.stop()
            self.heldKeepAlive = nil
        }
        pictureInPicture.onDidStart = nil
        pictureInPicture.onFailedToStart = nil
        pictureInPicture.onPauseChanged = nil
        // The return button with nothing to return to yet: let AVKit finish;
        // the next stream opens in its window instead (onHoldEnded).
        pictureInPicture.onRestoreRequested = { ready in ready() }
        pictureInPicture.onDidStop = { [weak self] restoreRequested in
            guard let self, self.isHolding else { return }
            self.isHolding = false
            self.holdGeneration &+= 1
            self.finishHold()
            Diag.info("PiP switch: Picture in Picture closed while switching (return=\(restoreRequested))", "Stream.PiP")
            self.onHoldEnded?(restoreRequested)
        }
    }
}
