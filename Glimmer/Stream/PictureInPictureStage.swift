//
//  PictureInPictureStage.swift
//
//  Apple's Picture in Picture, owned by the app rather than by one stream:
//  one AVKit controller on one layer, reused by every stream. A stream window
//  claims it when it starts PiP (`claim`) and lets it go when it closes
//  (`release`); its handlers are the only ones installed. A Switch PC in PiP
//  closes the old stream's PiP and opens the next one's - never in place - and
//  the next start waits for the close to finish (one controller).
//
//  The layer outlives streams, so each new stream starts its timeline over
//  (`prepareForNextStream`, measured 2026-11-16 with a bare harness: without
//  a flush, frames stamped below the previous stream's never show).
//

import AppKit
import AVFoundation

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

    private init() {
        pictureInPicture = StreamPictureInPicture(layer: source.layer)
    }

    func isOwned(by window: StreamWindow) -> Bool { owner === window }

    /// `window` starts PiP on the stage; its handlers are installed by the caller.
    func claim(by window: StreamWindow) {
        owner = window
    }

    /// `window` closed or gave PiP up.
    func release(by window: StreamWindow) {
        guard owner === window else { return }
        owner = nil
    }

    /// Closing as its × does (`close(by:)`), until AVKit reports PiP gone.
    private(set) var isClosing = false

    /// Nothing on the stage: no PiP up, starting, or closing. A new PiP start
    /// waits for this - AVKit has one controller and won't start mid-close.
    var isFree: Bool { !isClosing && !pictureInPicture.isInUse }

    /// Close PiP at once, where it is. Its × can't be pressed from code (the
    /// controls are drawn outside Shimmer's process) and the PiP window
    /// ignores our frame and alpha, so its close animation can't be had; a
    /// copy drawn with the source window looked wrong (2026-11-17). Stopping
    /// PiP from code plays the "return to app" animation instead, flying the
    /// picture back to the source layer - which sat elsewhere and was hidden at
    /// once, so a black rectangle grew out of the PiP towards the middle of the
    /// screen (recorded 2026-11-17). So the source goes exactly where the PiP
    /// is (the return has nowhere to go) and leaves the screen only once AVKit
    /// reports PiP gone. Call it while the stream still feeds the layer
    /// (`StreamWindow.closePictureInPicture`): the return draws the layer, and
    /// an ended stream's is empty - black, for a moment, where the PiP was.
    func close(by window: StreamWindow) {
        guard owner === window else { return }
        owner = nil
        guard pictureInPicture.isInUse else {
            finishClosing()
            return
        }
        isClosing = true
        if let panel = fitter.panel { source.place(at: panel.frame) }
        pictureInPicture.reset()
        awaitClosed(attempt: 0)
    }

    /// Poll until AVKit has let go (up to ~3 s), then clear the stage.
    private func awaitClosed(attempt: Int) {
        if pictureInPicture.isInUse, attempt < 60 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.awaitClosed(attempt: attempt + 1) }
            }
            return
        }
        finishClosing()
    }

    private func finishClosing() {
        fitter.detach()
        source.hide()
        isClosing = false
    }

    /// A new stream is about to feed the layer: start its timeline over. Keeps
    /// the picture that's up - a previous stream's PiP may still be animating
    /// closed - until the new frames arrive.
    func prepareForNextStream() {
        source.layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
    }
}
