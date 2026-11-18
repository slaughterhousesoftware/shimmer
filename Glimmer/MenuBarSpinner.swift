//
//  MenuBarSpinner.swift
//
//  The menu bar's loading spinner: the approved pyramid (design/pyramid-
//  spinner-size-rounding, variant 06 "14% larger · softer corners", with the
//  05 "every 1.20 s" motion). 72 prepared template frames (asset catalog
//  MenuBarSpinner-000…071, 24 × 18 pt at 1x/2x/3x) played at 60 fps, one turn
//  with its slowdown every 1.20 s. The frames carry the three tones (100, 75
//  and 45% opacity) and the 14% enlargement; nothing is drawn here.
//
//  Played by Core Animation, not by swapping the button's image: an image
//  swap redraws the whole status item on the main thread, and at 60 a second
//  that measured ~25% of the main thread (700 ms CPU in 5 s). Here the frames
//  are a discrete keyframe animation of a mask's contents, run by the render
//  server; the main thread only sets it up and takes it down. The mask's alpha
//  keeps the three tones; the layer under it is the menu bar's text colour,
//  which is what a template image is drawn in.
//

import AppKit
import QuartzCore

@MainActor
final class MenuBarSpinner: NSObject {
    nonisolated static let frameCount = 72
    nonisolated static let period: TimeInterval = 1.2
    nonisolated static let framesPerSecond = 60.0
    static let size = NSSize(width: 24, height: 18)

    /// The frame showing `elapsed` seconds after the spinner started.
    nonisolated static func frameIndex(elapsed: TimeInterval) -> Int {
        // Whole frames since the start (a hair of slack so 4.1 s is frame 246,
        // not 245.999…), then the place in the 72-frame turn. 72 frames at
        // 60 fps is exactly `period`.
        let framesSinceStart = Int(max(0, elapsed) * framesPerSecond + 1e-6)
        return framesSinceStart % frameCount
    }

    static func frameName(_ index: Int) -> String { String(format: "MenuBarSpinner-%03d", index) }

    static let frames: [NSImage] = (0..<frameCount).map { index in
        let image = NSImage(named: frameName(index)) ?? NSImage(size: size)
        image.isTemplate = true
        return image
    }

    /// Holds the spinner's width as the button's image while the layer above
    /// it shows the frames.
    static let placeholder: NSImage = {
        let image = NSImage(size: size)
        image.isTemplate = true
        return image
    }()

    /// The keyframe animation: one turn, frame by frame, repeating.
    static func animation(scale: CGFloat) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames.map { $0.layerContents(forContentsScale: scale) }
        // Discrete: each frame holds for exactly 1/60 s (73 key times for 72
        // values - the last closes the final frame's slot).
        animation.calculationMode = .discrete
        animation.keyTimes = (0...frameCount).map { NSNumber(value: Double($0) / Double(frameCount)) }
        animation.duration = period
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    private weak var button: NSStatusBarButton?
    private var tint: CALayer?
    private var mask: CALayer?
    private var appearanceObservation: NSKeyValueObservation?

    var isRunning: Bool { tint != nil }

    /// Start, or keep going: the label code may just have set the glyph as
    /// the button's image, so the placeholder goes back under the spinner.
    func run(in button: NSStatusBarButton) {
        self.button = button
        button.image = Self.placeholder
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if tint == nil {
            button.wantsLayer = true
            let tint = CALayer()
            let mask = CALayer()
            mask.contentsGravity = .center
            tint.mask = mask
            button.layer?.addSublayer(tint)
            self.tint = tint
            self.mask = mask
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.layout() }
            }
            mask.contentsScale = scale
            mask.add(Self.animation(scale: scale), forKey: "spin")
        } else if let mask, mask.contentsScale != scale {
            // Moved to a screen of another scale: frames for that scale.
            mask.contentsScale = scale
            mask.add(Self.animation(scale: scale), forKey: "spin")
        }
        layout()
    }

    func stop() {
        appearanceObservation = nil
        tint?.removeFromSuperlayer()
        tint = nil
        mask = nil
    }

    /// Centre the 24 × 18 pt spinner on the button and colour it the way the
    /// menu bar colours template images in the button's current appearance.
    private func layout() {
        guard let button, let tint, let mask else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = button.bounds
        tint.frame = CGRect(x: (bounds.width - Self.size.width) / 2,
                            y: (bounds.height - Self.size.height) / 2,
                            width: Self.size.width, height: Self.size.height).integral
        mask.frame = tint.bounds
        // labelColor under the button's appearance: measured on the mini's
        // menu bar, the system draws the idle template glyph at ~88% white
        // and labelColor is 85% - the closest system colour, and it follows a
        // light menu bar to black.
        var color = NSColor.labelColor.cgColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.cgColor
        }
        tint.backgroundColor = color
        CATransaction.commit()
    }
}
