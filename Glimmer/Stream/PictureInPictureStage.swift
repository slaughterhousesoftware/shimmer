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

    /// A new stream is about to feed the layer: start its timeline over. Keeps
    /// the picture that's up - a previous stream's PiP may still be animating
    /// closed - until the new frames arrive.
    func prepareForNextStream() {
        source.layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
    }
}
