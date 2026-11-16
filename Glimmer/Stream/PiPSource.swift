//
//  PiPSource.swift
//
//  The video layer Apple's Picture in Picture shows, in a window of its own.
//
//  AVKit's sample-buffer PiP mirrors its content layer into the system PiP
//  window (a CALayerHost), and the layer has to be on screen for the mirror to
//  have anything to show. Earlier the stream window itself was that source:
//  made invisible, reshaped and shrunk to the PiP window's size on every
//  resize - the size match was what kept the picture whole (the mirror is
//  unscaled, FB22411168), and the fragile part.
//
//  Now PiP has its own layer here. The decoder feeds it the same decoded
//  frames as the stream window (`VideoDecoder.setMirrorLayer`), so moving the
//  picture between the two costs no decode work, no keyframe and no delay. The
//  window is invisible (alpha 0), click-through, never key, and shaped like a
//  floating tool panel so Stage Manager and Mission Control leave it alone.
//  It never has to match the PiP window: `PiPPanelFitter` scales the mirror
//  inside the PiP window instead.
//
//  Its size is the stream's own resolution (1920x1080 pixels for a 1080p
//  stream), so the mirror carries every decoded pixel and the PiP window
//  scales it once. Where it sits only shapes AVKit's animations - they fly
//  between this layer's rect and the PiP window - so it is placed over the
//  stream window when PiP starts or ends there, and over the PiP window's last
//  spot for a stream that opens straight into PiP.
//

import AppKit
import AVFoundation

@MainActor
final class PiPSource {
    let layer: AVSampleBufferDisplayLayer
    let window: NSWindow
    private let view: NSView

    init() {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.isOpaque = true
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .transient, .ignoresCycle,
                                     .fullScreenAuxiliary]
        window.title = "Shimmer Picture in Picture source"
        // Layer-HOSTING (layer first, then wantsLayer), as the stream window's
        // view: the video layer is the root, the EDR-direct path for HDR.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
        view.layer = layer
        view.wantsLayer = true
        window.contentView = view
    }

    var isOnScreen: Bool { window.isVisible }

    /// Put the (invisible) source on screen at `frame`.
    func show(at frame: NSRect) {
        place(at: frame)
        window.orderFrontRegardless()
    }

    /// Move / resize without changing visibility.
    func place(at frame: NSRect) {
        guard frame.width >= 1, frame.height >= 1 else { return }
        window.setFrame(frame, display: false)
        layer.frame = view.bounds
    }

    func hide() {
        window.orderOut(nil)
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    // MARK: - Geometry (pure)

    /// The source at the stream's own pixel size (points = pixels / scale),
    /// centred on `center`, clamped to stay on `screen` (an off-screen mirror
    /// source shows nothing) - shrunk to fit if it is bigger than the screen.
    nonisolated static func nativeFrame(pixelSize: CGSize, backingScale: CGFloat,
                                        center: CGPoint, screen: CGRect) -> CGRect {
        let scale = max(backingScale, 1)
        var size = pixelSize.width > 0 && pixelSize.height > 0
            ? CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
            : CGSize(width: 960, height: 540)
        let fit = min(1, screen.width / size.width, screen.height / size.height)
        size = CGSize(width: (size.width * fit).rounded(.down), height: (size.height * fit).rounded(.down))
        var origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        return CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }
}
