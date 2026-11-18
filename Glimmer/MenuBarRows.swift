//
//  MenuBarRows.swift
//
//  The menu bar menu's custom rows: the Sound menu's volume slider, copied
//  (a quiet speaker, the slider, a loud speaker, nothing else - Kevin,
//  2026-11-18: "just copy this"), and the Servers list, drawn the way
//  Control Center's Focus list is: each machine's mark on a round disc,
//  grey when off, in its own colours when it's the one in use.
//

import AppKit

/// The stream volume, 0 (silent) to full. A custom row, the way the Sound menu
/// carries its own slider; a menu has no slider item of its own.
final class MenuVolumeSlider: NSView {
    private let slider = NSSlider()
    private let onChange: (Double) -> Void

    init(level: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 30))
        autoresizingMask = [.width]
        let quiet = NSImageView(image: NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil) ?? NSImage())
        let loud = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil) ?? NSImage())
        for end in [quiet, loud] {
            end.contentTintColor = .labelColor
            end.setAccessibilityElement(false)
        }
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = level
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)
        slider.setAccessibilityLabel("Stream volume")
        for view in [quiet, slider, loud] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // 16 pt in from the edge lines the quiet speaker up with the titles of
        // the plain rows (measured off a real menu at 2x).
        NSLayoutConstraint.activate([
            quiet.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            quiet.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: quiet.trailingAnchor, constant: 6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            loud.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            loud.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            loud.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func moved() { onChange(slider.doubleValue) }
}

/// A server's round mark for its menu row, in the design language of
/// Control Center's Focus list (measured off a macOS 27 Focus menu at 2x,
/// 2026-11-18): a 26 pt disc with the mark at about half its size, centred
/// on its ink; off, the disc an 8% grey and the mark a 50% grey. On, the
/// real logo rather than Focus's pale tint - a tinted, shrunken Bazzite mark
/// stopped looking like Bazzite (Kevin): Bazzite's own logo file as it is,
/// the PlayStation logo white on PlayStation blue, a distro's mark white on
/// its colour (the Settings sidebar's avatars). A logo that is a disc with
/// its mark (Bazzite) keeps that mark's size and place when it goes grey.
@MainActor
enum MenuHostMark {
    static let diameter: CGFloat = 26

    enum Look { case current, off, offHighlighted }

    /// The mark's artwork and the colours of its brand (two for a gradient).
    struct Art {
        let image: NSImage
        let key: String
        let colours: [NSColor]
        /// Moves the ink off its box's centre, as fractions of the ink's
        /// width and height (y up), for a mark whose weight sits far from
        /// that centre.
        var optical = CGVector.zero
        /// The whole logo, drawn as it is for the machine in use, when the
        /// brand's logo is itself a disc with its mark.
        var logo: NSImage?
        /// Where `image` (the mark alone) sits in `logo`, as fractions of
        /// the disc (y up) - kept for the grey disc, so it stays the logo.
        var placement: CGRect?
    }

    static func art(for mark: HostAvatar.Mark) -> Art {
        func symbol(_ name: String, _ rgb: UInt32) -> Art {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 64, weight: .regular)) ?? NSImage()
            return Art(image: image, key: "symbol:" + name, colours: [colour(rgb)])
        }
        switch mark {
        case .playStation:
            // The logo's weight is low and a little right of its box's
            // centre (the S's wide sweep under the P): measured off the
            // symbol, its centre of mass is 6.5% of its height lower than its
            // box's. Lifted by that much it stops reading as sitting low on
            // the disc (Kevin, 2026-11-18).
            // Only lifted: centring its weight sideways too pulled it left
            // of where the eye puts it.
            var art = symbol("playstation.logo", 0x0070D1)
            art.optical = CGVector(dx: 0, dy: 0.065)
            return art
        case .icon(.bazzite):
            // The press kit's logo: a 500-unit disc (viewBox 50-550) with the
            // mark's own artwork at 124.9-475.1 - 15% in, 70% of the disc.
            var art = Art(image: NSImage(named: "HostLogo-bazzite-mark") ?? NSImage(), key: "HostLogo-bazzite-mark",
                          colours: [colour(0x0047AB), colour(0x8A2BE2)])
            art.logo = NSImage(named: "HostLogo-bazzite")
            art.placement = CGRect(x: 74.9 / 500, y: 74.9 / 500, width: 350.2 / 500, height: 350.2 / 500)
            return art
        case .icon(.chimeraOS):
            return symbol("gamecontroller.fill", HostIcon.chimeraOS.backgroundRGB)
        case .icon(.macOS):
            return symbol("apple.logo", HostIcon.macOS.backgroundRGB)
        case .icon(.computer), .icon(.automatic):
            return symbol("desktopcomputer", HostIcon.computer.backgroundRGB)
        case .icon(let icon):
            let name = icon.assetName ?? "HostLogo-linux"
            return Art(image: NSImage(named: name) ?? NSImage(), key: name, colours: [colour(icon.backgroundRGB)])
        }
    }

    /// The mark's ink size in a disc `size` across: the geometric mean of
    /// its sides half the disc (the Focus moon is 13 pt in 26), its longest
    /// side at most 64% (the Focus bed is 16.5 pt wide).
    nonisolated static func inkSize(aspect: CGFloat, size: CGFloat, optical: CGFloat = 1) -> CGSize {
        let side = size * 0.5 * optical
        var width = side * aspect.squareRoot(), height = side / aspect.squareRoot()
        let longest = max(width, height), cap = size * 0.64
        if longest > cap { width *= cap / longest; height *= cap / longest }
        return CGSize(width: width, height: height)
    }

    static func image(for host: Host, look: Look, appearance: NSAppearance) -> NSImage {
        let mark = HostAvatar.mark(for: host)
        let art = art(for: mark)
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        // The colours, settled now for the menu's appearance.
        let disc: NSColor
        let ink: [NSColor]
        switch look {
        case .off:
            disc = dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)
            ink = [dark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.5)]
        case .offHighlighted:
            // On the menu's blue highlight: white, as a template image turns.
            disc = NSColor.white.withAlphaComponent(0.22)
            ink = [.white]
        case .current:
            if let logo = art.logo {
                let d = diameter
                let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
                    logo.draw(in: rect)
                    return true
                }
                image.accessibilityDescription = HostAvatar.name(of: mark)
                return image
            }
            disc = art.colours[0]
            // Linux's Tux stays black on its yellow, as in Settings.
            ink = [mark == .icon(.linux) ? .black : .white]
        }

        let measure = InkMeasure.measure(art.image, key: art.key)
        let box = measure.inkBox
        let imageSize = art.image.size
        let aspect = imageSize.height > 0 ? imageSize.width / imageSize.height : 1
        let inkSize = inkSize(aspect: aspect * box.width / max(box.height, 0.01), size: diameter,
                              optical: measure.optical)
        // The whole artwork's size for that much ink - or the logo's own.
        let frame = art.placement.map { CGSize(width: $0.width * diameter, height: $0.height * diameter) }
            ?? CGSize(width: inkSize.width / max(box.width, 0.01), height: inkSize.height / max(box.height, 0.01))
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        // A bitmap for each screen scale, its mark measured in that bitmap
        // and set on the disc's centre to the pixel: at menu sizes a symbol
        // lands on the pixel grid differently than in a big scan, which left
        // the PlayStation logo half a point left of centre.
        for scale in [1, 2, 3] as [CGFloat] {
            if let rep = render(art: art, disc: disc, ink: ink, frame: frame, inkSize: inkSize, scale: scale) {
                image.addRepresentation(rep)
            }
        }
        image.accessibilityDescription = HostAvatar.name(of: mark)
        return image
    }

    /// One bitmap of the disc and its mark at `scale` pixels a point.
    private static func render(art: Art, disc: NSColor, ink: [NSColor], frame: CGSize, inkSize: CGSize,
                               scale: CGFloat) -> NSBitmapImageRep? {
        let side = Int((diameter * scale).rounded())
        let glyphWidth = Int((frame.width * scale).rounded(.up)) + 2
        let glyphHeight = Int((frame.height * scale).rounded(.up)) + 2
        guard imageSizeIsUsable(art.image),
              let glyph = CGContext(data: nil, width: glyphWidth, height: glyphHeight, bitsPerComponent: 8,
                                    bytesPerRow: glyphWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = glyph.data,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        // Drawn in pixels; given its size in points once it's done.
        rep.size = NSSize(width: side, height: side)
        defer { rep.size = NSSize(width: diameter, height: diameter) }

        // The mark, tinted opaque (a translucent tint over the artwork's own
        // black would leave the black showing; its opacity comes later).
        let opaque = ink.map { $0.withAlphaComponent(1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: glyph, flipped: false)
        let inner = NSRect(x: 1, y: 1, width: frame.width * scale, height: frame.height * scale)
        art.image.draw(in: inner)
        NSGraphicsContext.current?.compositingOperation = .sourceAtop
        if opaque.count > 1, let gradient = NSGradient(colors: opaque) {
            gradient.draw(in: inner, angle: -45)
        } else {
            opaque[0].setFill()
            inner.fill(using: .sourceAtop)
        }
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep), let mark = glyph.makeImage() else { return nil }
        NSGraphicsContext.current = context
        let cg = context.cgContext
        let whole = CGRect(x: 0, y: 0, width: side, height: side)
        cg.setFillColor(disc.cgColor)
        cg.fillEllipse(in: whole)
        cg.setAlpha(ink[0].alphaComponent)
        let markSize = CGSize(width: CGFloat(glyphWidth), height: CGFloat(glyphHeight))

        // A logo's own geometry, where it has one.
        if let placement = art.placement {
            cg.draw(mark, in: CGRect(origin: CGPoint(x: placement.minX * diameter * scale - 1,
                                                     y: placement.minY * diameter * scale - 1), size: markSize))
            return rep
        }

        // Where its ink landed (pixels at least half opaque; rows in memory
        // run down from the top).
        let bytes = pixels.bindMemory(to: UInt8.self, capacity: glyphWidth * glyphHeight * 4)
        var minX = glyphWidth, maxX = -1, minRow = glyphHeight, maxRow = -1
        for row in 0..<glyphHeight {
            let line = bytes + row * glyphWidth * 4 + 3
            for x in 0..<glyphWidth where line[x * 4] > 127 {
                minX = min(minX, x); maxX = max(maxX, x); minRow = min(minRow, row); maxRow = max(maxRow, row)
            }
        }
        guard maxX >= 0 else { return nil }
        let inkMidX = CGFloat(minX + maxX + 1) / 2
        let inkMidY = CGFloat(glyphHeight) - CGFloat(minRow + maxRow + 1) / 2   // y up
        // The ink's centre on the disc's, plus the mark's own lift, whole
        // pixels so it stays crisp.
        let x = (CGFloat(side) / 2 - inkMidX + art.optical.dx * inkSize.width * scale).rounded()
        let y = (CGFloat(side) / 2 - inkMidY + art.optical.dy * inkSize.height * scale).rounded()
        cg.draw(mark, in: CGRect(origin: CGPoint(x: x, y: y), size: markSize))
        return rep
    }

    private static func imageSizeIsUsable(_ image: NSImage) -> Bool {
        image.size.width > 0 && image.size.height > 0
    }

    private static func colour(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

/// A server in the Servers list: its round mark and its name, highlighted the
/// way every other row of the menu is (the menu's own blue selection, the
/// name in white), and a click that switches without closing the menu, as
/// the Sound menu's outputs do. The controller says when it's highlighted
/// (`isHovered`, from NSMenuDelegate's willHighlight): a custom row isn't
/// redrawn by the menu when the highlight moves on, which left the grey
/// band behind on the last row the pointer crossed.
final class MenuServerRow: NSView {
    private let title: String
    private let marks: (normal: NSImage, highlighted: NSImage)
    private let onPick: () -> Void
    private let selection = NSVisualEffectView()
    private let content = Content()

    static let height: CGFloat = 32

    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            selection.isHidden = !isHovered
            content.needsDisplay = true
        }
    }

    init(title: String, marks: (normal: NSImage, highlighted: NSImage), onPick: @escaping () -> Void) {
        self.title = title
        self.marks = marks
        self.onPick = onPick
        super.init(frame: .zero)
        // The menu sizes itself to its widest row; the view then stretches.
        setFrameSize(intrinsicContentSize)
        autoresizingMask = [.width]

        // The menu's own selection material - the blue (accent) band the
        // plain rows above and below get, 5 pt in from each side.
        selection.material = .selection
        selection.state = .active
        selection.isEmphasized = true
        selection.blendingMode = .behindWindow
        selection.maskImage = Self.selectionMask
        selection.isHidden = true
        selection.frame = bounds.insetBy(dx: 5, dy: 0)
        selection.autoresizingMask = [.width, .height]
        addSubview(selection)

        content.row = self
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The selection's corners, measured off a plain row's highlight on
    /// macOS 27 (6 pt).
    private static let selectionMask: NSImage = {
        let radius: CGFloat = 6
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }()

    /// Wide enough for the name, so the menu sizes itself around it.
    override var intrinsicContentSize: NSSize {
        NSSize(width: 16 + MenuHostMark.diameter + 8 + titleSize(highlighted: false).width + 24, height: Self.height)
    }

    fileprivate func titleAttributes(highlighted: Bool) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.menuFont(ofSize: 0),
         .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor]
    }

    fileprivate func titleSize(highlighted: Bool) -> NSSize {
        (title as NSString).size(withAttributes: titleAttributes(highlighted: highlighted))
    }

    /// The disc and the name, above the selection band.
    private final class Content: NSView {
        weak var row: MenuServerRow?

        override func draw(_ dirtyRect: NSRect) {
            guard let row else { return }
            let lit = row.isHovered
            let d = MenuHostMark.diameter
            (lit ? row.marks.highlighted : row.marks.normal)
                .draw(in: NSRect(x: 16, y: ((bounds.height - d) / 2).rounded(), width: d, height: d))
            let size = row.titleSize(highlighted: lit)
            (row.title as NSString).draw(at: NSPoint(x: 16 + d + 8, y: (bounds.height - size.height) / 2),
                                         withAttributes: row.titleAttributes(highlighted: lit))
        }

        // The row takes the clicks.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPick()
    }

    override func accessibilityPerformPress() -> Bool {
        onPick()
        return true
    }
}
