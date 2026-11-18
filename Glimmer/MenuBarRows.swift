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

/// A server's round mark for its menu row: the Settings sidebar's avatar
/// (HostAvatar) for the machine in use - its brand's disc with the mark in
/// white (PlayStation blue, Bazzite's blue-to-purple) - and, for the rest,
/// the same mark at the same size and place in grey, as Control Center's
/// Focus list draws what's off (an 8% grey disc, a 50% grey mark; measured
/// off a macOS 27 Focus menu at 2x, 2026-11-18). 26 pt, like Focus's discs.
///
/// Sized and placed by the sidebar's rule, which Kevin approved there
/// (2026-11-17): every mark the same optical area (HostAvatar.glyphFrame),
/// set by its measured ink box exactly on the disc's centre - no optical
/// shifts. Each disc is a bitmap per screen scale with its mark measured in
/// that bitmap and centred to the pixel: a symbol lands on the pixel grid
/// differently at menu size than in a big scan, which had left the
/// PlayStation logo half a point left.
@MainActor
enum MenuHostMark {
    static let diameter: CGFloat = 26

    enum Look { case current, off, offHighlighted }

    /// The mark's artwork and its brand's disc colours (two for a gradient).
    struct Art {
        let image: NSImage
        let key: String
        let colours: [NSColor]
    }

    static func art(for mark: HostAvatar.Mark) -> Art {
        func symbol(_ name: String, _ rgb: UInt32) -> Art {
            // Drawn from the same NSImage that is measured (the sidebar's
            // symbols are made the same way).
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 64, weight: .regular)) ?? NSImage()
            return Art(image: image, key: "symbol:" + name, colours: [colour(rgb)])
        }
        switch mark {
        case .playStation:
            return symbol("playstation.logo", 0x0070D1)
        case .icon(.bazzite):
            return Art(image: NSImage(named: "HostLogo-bazzite-mark") ?? NSImage(), key: "HostLogo-bazzite-mark",
                       colours: [colour(0x0047AB), colour(0x8A2BE2)])
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

    static func image(for host: Host, look: Look, appearance: NSAppearance) -> NSImage {
        let mark = HostAvatar.mark(for: host)
        let art = art(for: mark)
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        // The colours, settled now for the menu's appearance.
        let disc: [NSColor]
        let ink: NSColor
        switch look {
        case .current:
            disc = art.colours
            // Tux stays black on its yellow, as in Settings.
            ink = mark == .icon(.linux) ? .black : .white
        case .off:
            disc = [dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)]
            ink = dark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.5)
        case .offHighlighted:
            // On the menu's blue highlight: white, as a template image turns.
            disc = [NSColor.white.withAlphaComponent(0.22)]
            ink = .white
        }

        // The sidebar's size for this mark's ink, scaled to the menu's disc.
        let measure = InkMeasure.measure(art.image, key: art.key)
        let box = measure.inkBox
        let imageSize = art.image.size
        let aspect = imageSize.height > 0 ? imageSize.width / imageSize.height : 1
        let inkSize = HostAvatar.glyphFrame(aspect: aspect * box.width / max(box.height, 0.01), size: diameter,
                                            optical: measure.optical)
        // The whole artwork's size for that much ink.
        let frame = CGSize(width: inkSize.width / max(box.width, 0.01), height: inkSize.height / max(box.height, 0.01))
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        for scale in [1, 2, 3] as [CGFloat] {
            if let rep = render(art: art, disc: disc, ink: ink, frame: frame, scale: scale) {
                image.addRepresentation(rep)
            }
        }
        image.accessibilityDescription = HostAvatar.name(of: mark)
        return image
    }

    /// One bitmap of the disc and its mark at `scale` pixels a point.
    private static func render(art: Art, disc: [NSColor], ink: NSColor, frame: CGSize,
                               scale: CGFloat) -> NSBitmapImageRep? {
        let side = Int((diameter * scale).rounded())
        let glyphWidth = Int((frame.width * scale).rounded(.up)) + 2
        let glyphHeight = Int((frame.height * scale).rounded(.up)) + 2
        guard art.image.size.width > 0, art.image.size.height > 0,
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
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: glyph, flipped: false)
        let inner = NSRect(x: 1, y: 1, width: frame.width * scale, height: frame.height * scale)
        art.image.draw(in: inner)
        ink.withAlphaComponent(1).setFill()
        inner.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()

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
        guard maxX >= 0, let mark = glyph.makeImage() else { return nil }
        let inkMidX = CGFloat(minX + maxX + 1) / 2
        let inkMidY = CGFloat(glyphHeight) - CGFloat(minRow + maxRow + 1) / 2   // y up

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        let cg = context.cgContext
        let whole = CGRect(x: 0, y: 0, width: side, height: side)
        if disc.count > 1, let gradient = NSGradient(colors: disc) {
            // Top left to bottom right, as the sidebar's Bazzite disc.
            gradient.draw(in: NSBezierPath(ovalIn: whole), angle: -45)
        } else {
            cg.setFillColor(disc[0].cgColor)
            cg.fillEllipse(in: whole)
        }
        // The ink box's centre on the disc's, in whole pixels so it stays crisp.
        let x = (CGFloat(side) / 2 - inkMidX).rounded()
        let y = (CGFloat(side) / 2 - inkMidY).rounded()
        cg.setAlpha(ink.alphaComponent)
        cg.draw(mark, in: CGRect(x: x, y: y, width: CGFloat(glyphWidth), height: CGFloat(glyphHeight)))
        return rep
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
