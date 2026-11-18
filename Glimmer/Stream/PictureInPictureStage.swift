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

    /// Close PiP the way its × does - it shrinks into its centre and fades,
    /// still playing. There is no way to press ×: the PiP's controls are drawn
    /// outside Shimmer's process, and the PiP window itself ignores our frame
    /// and alpha (measured 2026-11-17). Stopping PiP from code plays the
    /// "return to app" animation instead, flying the picture to the source
    /// layer - a black rectangle grew out of the PiP when the source sat
    /// elsewhere, hidden. So the source window - ours, animatable - takes the
    /// PiP's exact place showing the same live picture, PiP stops into it with
    /// nothing to fly, and the source does the × animation. Call it while the
    /// stream still feeds the layer (`StreamWindow.closePictureInPicture`).
    func close(by window: StreamWindow) {
        guard owner === window else { return }
        owner = nil
        guard pictureInPicture.isInUse else {
            finishClosing()
            return
        }
        isClosing = true
        guard let panel = fitter.panel else {
            pictureInPicture.reset()
            awaitClosed(attempt: 0)
            return
        }
        // The source takes the PiP's place, showing the same live picture,
        // and PiP stops: its return lands where it already is, so nothing
        // moves. Then the source closes the way × does.
        let rect = panel.frame
        source.place(at: rect)
        source.showInPlaceOfPiP()
        pictureInPicture.reset()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            awaitClosed(attempt: 0)
            return
        }
        let window = source.window
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.closeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(Self.closedFrame(of: rect), display: true)
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { self.awaitClosed(attempt: 0) }
        })
    }

    /// The × animation, measured from a recording of a real × click on macOS
    /// 27.2 (2026-11-17): the picture shrinks to about half size around its
    /// centre while fading out, still playing - about 10 frames at 75 Hz. An
    /// eased-in 0.2 s reads the same length (0.16 s looked short, 7 frames).
    static let closeDuration: TimeInterval = 0.2

    /// Where the × animation ends: half size, around the same centre.
    nonisolated static func closedFrame(of frame: NSRect) -> NSRect {
        frame.insetBy(dx: frame.width / 4, dy: frame.height / 4)
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
        source.backToInvisible()
        isClosing = false
    }

    /// A new stream is about to feed the layer: start its timeline over. Keeps
    /// the picture that's up - a previous stream's PiP may still be animating
    /// closed - until the new frames arrive.
    func prepareForNextStream() {
        source.layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
    }
}
