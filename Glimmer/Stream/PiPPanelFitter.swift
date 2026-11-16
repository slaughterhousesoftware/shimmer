//
//  PiPPanelFitter.swift
//
//  Makes Apple's Picture in Picture window show the whole picture.
//
//  macOS's sample-buffer PiP (FB22411168, still present on macOS 27.2.1 -
//  measured 2026-11-16) puts the source layer's mirror into the PiP window at
//  the SOURCE's size, unscaled, so the window shows only its bottom-left
//  corner. It also lays an empty opaque overlay over the top, and can offset
//  the video inside its own container. The PiP window (`PIPPanel`) is a window
//  of our own process, so this fixes its geometry in place:
//
//    * the panel content's sublayer transform scales AVKit's video view (the
//      source's size) to the panel - whatever the source's size;
//    * the video container's sublayer transform maps the picture exactly
//      onto its host, undoing AVKit's offset;
//    * the overlay is hidden;
//    * the panel's background is black, so any instant where the picture and
//      the window disagree (a fast resize) reads as a letterbox, never white.
//
//  Every value is computed from the layout AVKit actually built; if Apple
//  fixes the bug each one comes out as identity and this does nothing.
//  It re-fits on every size change of the panel or the video view (they
//  fire through a live resize), when AVKit rewrites the container's transform,
//  and on a short safety beat for changes nothing announces.
//
//  Approach after Lume's MacPictureInPictureScaler (github.com/bilipp/Lume,
//  AGPL-3.0, PR #252), written for Shimmer.
//

import AppKit
import QuartzCore

@MainActor
final class PiPPanelFitter {
    /// The panel found (non-nil) or let go (nil): input mirroring and the
    /// recording keep-alive attach to it.
    var onPanelChanged: ((NSWindow?) -> Void)?

    private(set) weak var panel: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var transformObservation: NSKeyValueObservation?
    private var safetyTimer: Timer?
    private var searchGeneration = 0
    private(set) var fits = 0

    /// PiP started: find the panel (it can appear a beat after didStart) and
    /// keep it fitted until `detach()`.
    func attach() {
        detach()
        searchGeneration &+= 1
        search(generation: searchGeneration, attempt: 0)
    }

    func detach() {
        searchGeneration &+= 1
        safetyTimer?.invalidate()
        safetyTimer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        transformObservation = nil
        if panel != nil {
            panel = nil
            onPanelChanged?(nil)
        }
    }

    private func search(generation: Int, attempt: Int) {
        guard generation == searchGeneration else { return }
        if let found = Self.findPanel(), let content = found.contentView {
            // Black from the panel's first frame: until AVKit's video view is
            // there, the panel is otherwise its white default.
            if let layer = content.layer {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                layer.backgroundColor = CGColor(gray: 0, alpha: 1)
                CATransaction.commit()
            }
            if Self.videoView(in: content) != nil {
                install(on: found, content: content)
                return
            }
        }
        guard attempt < 60 else {
            Diag.error("PiP: the Picture in Picture window never appeared - picture left as AVKit drew it", "Stream.PiP")
            return
        }
        // Fit as early as possible: the first frames AVKit draws are the ones
        // that would show the crop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            MainActor.assumeIsolated { self?.search(generation: generation, attempt: attempt + 1) }
        }
    }

    private func install(on found: NSWindow, content: NSView) {
        panel = found
        let video = Self.videoView(in: content)
        for view in [content, video].compactMap({ $0 }) {
            view.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.fit() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: found, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fit() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: found, queue: .main
        ) { [weak found] _ in
            MainActor.assumeIsolated { if let found { StreamWindow.rememberPiPPanelFrame(found.frame) } }
        })
        if let container = video.flatMap(Self.videoContainerLayer) {
            transformObservation = container.observe(\.sublayerTransform) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.fit() }
            }
        }
        fit()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fit() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer
        onPanelChanged?(found)
        if let content = found.contentView, let video = Self.videoView(in: content) {
            Diag.info("PiP: fitting \(Int(video.frame.width))x\(Int(video.frame.height)) source into "
                + "\(Int(content.bounds.width))x\(Int(content.bounds.height)) panel", "Stream.PiP")
        }
    }

    /// Idempotent: writes only what differs, without implicit animation.
    func fit() {
        guard let panel, let content = panel.contentView, let video = Self.videoView(in: content) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        Self.hideOverlays(in: video)
        let black = CGColor(gray: 0, alpha: 1)
        if let layer = content.layer, layer.backgroundColor != black { layer.backgroundColor = black }
        if let layer = video.layer, layer.backgroundColor != black { layer.backgroundColor = black }
        if let container = Self.videoContainerLayer(in: video),
           let host = container.superlayer?.bounds.size,
           let mapping = Self.containerMapping(picture: container.sublayers?.first?.frame ?? container.bounds,
                                               layerFrame: container.frame,
                                               anchorPoint: container.anchorPoint, host: host),
           !Self.approximatelyEqual(container.sublayerTransform, mapping) {
            container.sublayerTransform = mapping
        }
        if let layer = content.layer,
           let scale = Self.panelScale(video: video.frame.size, panel: content.bounds.size),
           !Self.approximatelyEqual(layer.sublayerTransform, scale) {
            layer.sublayerTransform = scale
            fits += 1
        }
        StreamWindow.rememberPiPPanelFrame(panel.frame)
    }

    // MARK: - Geometry (pure)

    /// Scales AVKit's video view (anchored at the panel's origin) onto the
    /// panel. Nil for an empty size; identity once they already match.
    nonisolated static func panelScale(video: CGSize, panel: CGSize) -> CATransform3D? {
        guard video.width > 0, video.height > 0, panel.width > 0, panel.height > 0 else { return nil }
        return CATransform3DMakeScale(panel.width / video.width, panel.height / video.height, 1)
    }

    /// The sublayer transform that lands `picture` (a rect in the container's
    /// own coordinates) exactly on the container's host bounds. A sublayer
    /// transform pivots on the layer's anchor point, so the translation undoes
    /// the pivot, the layer's offset in its host and the picture's offset.
    nonisolated static func containerMapping(picture: CGRect, layerFrame: CGRect, anchorPoint: CGPoint,
                                             host: CGSize) -> CATransform3D? {
        guard picture.width > 0, picture.height > 0, host.width > 0, host.height > 0 else { return nil }
        let sx = host.width / picture.width
        let sy = host.height / picture.height
        var t = CATransform3DMakeScale(sx, sy, 1)
        t.m41 = anchorPoint.x * layerFrame.width * (sx - 1) - layerFrame.minX - picture.minX * sx
        t.m42 = anchorPoint.y * layerFrame.height * (sy - 1) - layerFrame.minY - picture.minY * sy
        return t
    }

    nonisolated static func approximatelyEqual(_ a: CATransform3D, _ b: CATransform3D) -> Bool {
        let e: CGFloat = 0.0005
        return CATransform3DIsAffine(a) && CATransform3DIsAffine(b)
            && abs(a.m11 - b.m11) < e && abs(a.m22 - b.m22) < e
            && abs(a.m41 - b.m41) < e && abs(a.m42 - b.m42) < e
    }

    // MARK: - AVKit's private views, by class name (a miss leaves PiP as AVKit drew it)

    static func findPanel() -> NSWindow? {
        NSApp.windows.first { String(describing: type(of: $0)).contains("PIPPanel") }
    }

    static func videoView(in content: NSView) -> NSView? {
        content.subviews.first { String(describing: type(of: $0)).contains("SampleBufferDisplayLayerView") }
    }

    static func videoContainerLayer(in view: NSView) -> CALayer? {
        func search(_ layer: CALayer) -> CALayer? {
            if String(describing: type(of: layer)).contains("VideoContainerLayer") { return layer }
            for sub in layer.sublayers ?? [] { if let found = search(sub) { return found } }
            return nil
        }
        return view.layer.flatMap(search)
    }

    /// AVKit's empty, opaque overlay (`AVPictureInPictureCALayerHostView`).
    /// Never its parent, which carries the picture.
    static func hideOverlays(in view: NSView) {
        for sub in view.subviews {
            if String(describing: type(of: sub)) == "AVPictureInPictureCALayerHostView" {
                if !sub.isHidden { sub.isHidden = true }
            } else {
                hideOverlays(in: sub)
            }
        }
    }
}
