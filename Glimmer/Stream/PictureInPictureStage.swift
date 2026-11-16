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
    /// `--debug-pip-rate`: what the PiP window really shows, every 2 s.
    let rateSampler = PiPRateSampler()

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
        let held = displayedPictureSignature()
        Diag.info("PiP switch: holding the last frame while the next stream connects - showing \(held, privacy: .public)",
                  "Stream.PiP")
        return true
    }

    /// A new stream is about to feed the layer: start its timeline over. The
    /// layer outlives streams, and frames stamped earlier than the last
    /// stream's are never shown otherwise (measured: PS5 then Bazzite froze
    /// the PiP on the PS5's last frame, 2026-11-16). Keeps whatever picture is
    /// up (a held PiP's) until the new frames arrive.
    func prepareForNextStream() {
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
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let shown = self.displayedPictureSignature()
                    Diag.info("PiP switch: +\(delay) s after takeover the PiP shows \(shown, privacy: .public)",
                              "Stream.PiP")
                }
            }
        }
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
        rateSampler.stop()
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

    /// What the PiP layer is displaying, as "WxH fmt luma~N": enough to tell
    /// one stream's picture from another's in the log. (The renderer's own
    /// report can lag for 10-bit HDR frames; SDR is exact.)
    func displayedPictureSignature() -> String {
        guard let buffer = source.layer.sampleBufferRenderer.displayedPixelBuffer() else { return "nothing" }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((format >> $0) & 0xFF) }, encoding: .ascii) ?? "\(format)"
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
        else { return "\(width)x\(height) \(fourCC)" }
        let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        // A 16x9 grid of samples from the first plane (luma, or BGRA bytes).
        var sum = 0, count = 0
        for gy in 1...9 { for gx in 1...16 {
            let y = height * gy / 10, x = width * gx / 17
            let bytesPerSample = planar ? (rowBytes / max(width, 1) >= 2 ? 2 : 1) : 4
            sum += Int(bytes[y * rowBytes + x * bytesPerSample + (bytesPerSample == 2 ? 1 : 0)])
            count += 1
        } }
        return "\(width)x\(height) \(fourCC) luma~\(sum / max(count, 1))"
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
