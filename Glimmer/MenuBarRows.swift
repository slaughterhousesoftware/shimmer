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
        // 26 pt: the slider's middle 18.5 pt above the separator's line, as
        // the Sound menu's.
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 26))
        autoresizingMask = [.width]
        // The Sound menu's speakers, measured off it at 2x (macOS 27): the
        // loud one 21 x 15 pt - the symbols at 15.5 pt - in the secondary
        // grey, not the text colour.
        let size = NSImage.SymbolConfiguration(pointSize: 15.5, weight: .regular)
        func speaker(_ name: String) -> NSImageView {
            NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(size) ?? NSImage())
        }
        let quiet = speaker("speaker.fill")
        let loud = speaker("speaker.wave.3.fill")
        for end in [quiet, loud] {
            end.contentTintColor = .secondaryLabelColor
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
        // Control Center's inset lines the quiet speaker up with the rows'
        // discs and titles.
        NSLayoutConstraint.activate([
            quiet.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuRowView.contentInset),
            quiet.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: quiet.trailingAnchor, constant: 6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            loud.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            loud.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuRowView.contentInset),
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
/// Focus list draws what's off (a 9% grey disc, a 50% grey mark; measured
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

    enum Look { case current, off }

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
            disc = [dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.09)]
            ink = dark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.5)
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

/// A custom menu row with the hover of Apple's own menu bar menus (Focus,
/// Sound, Wi-Fi): a soft grey band under the pointer, the text staying as it
/// is - not the accent-blue bar AppKit gives a plain menu item, which no
/// Apple menu bar menu shows (Kevin, 2026-11-18). Measured off the Focus
/// menu at 2x: the band is the row's full height, 7 pt in from each side,
/// 10 pt corners on a 32 pt row, ~8% darker than the menu.
///
/// Every row lays out on Control Center's grid (measured off the Sound and
/// Focus menus at 2x, 2026-11-18): content 14 pt in from the row's edges
/// (`contentInset`) - discs, titles, headers and separators all start there.
///
/// The controller says when it's highlighted (`isHovered`, from
/// NSMenuDelegate's willHighlight): a custom row isn't redrawn by the menu
/// when the highlight moves on, which left the band behind on the last row
/// the pointer crossed. Subclasses draw their content (`drawContent`).
class MenuRowView: NSView {
    private let onPick: () -> Void
    private let hover = HoverFill()
    private let content = Content()

    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            hover.isHidden = !isHovered
            content.needsDisplay = true
        }
    }

    /// The hover band, drawn with vibrancy so it darkens whatever the
    /// menu's glass shows through, as the system's own does.
    private final class HoverFill: NSView {
        override var allowsVibrancy: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            let radius: CGFloat = bounds.height >= 30 ? 10 : 7
            MenuRowView.hoverColour.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
    }

    /// Control Center's content inset: where discs, titles, headers and
    /// separators start, from either side of the row.
    static let contentInset: CGFloat = 14

    /// The band's grey: ~8% over the menu, as measured (light); a light
    /// band of the same weight in the dark.
    static let hoverColour = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.075)
    }

    init(height: CGFloat, accessibilityTitle: String, onPick: @escaping () -> Void) {
        self.onPick = onPick
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: height))
        autoresizingMask = [.width]

        hover.isHidden = true
        hover.frame = bounds.insetBy(dx: 7, dy: 0)
        hover.autoresizingMask = [.width, .height]
        addSubview(hover)

        content.row = self
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityTitle)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Called once the subclass is set up: the menu sizes itself to its
    /// widest row, then the row stretches to the menu.
    func sizeToContent() { setFrameSize(intrinsicContentSize) }

    func drawContent(in bounds: NSRect) {}

    /// Redraws the content (a subclass's state changed), not the band.
    func redrawContent() { content.needsDisplay = true }

    static let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor,
    ]

    /// The content, above the hover band.
    private final class Content: NSView {
        weak var row: MenuRowView?

        override func draw(_ dirtyRect: NSRect) { row?.drawContent(in: bounds) }

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

/// A plain command row - a title and, if it has one, its shortcut at the
/// trailing edge - drawn by Shimmer so it hovers grey like the rest. A
/// click closes the menu and then sends the item's action, as a plain item
/// does.
final class MenuActionRow: MenuRowView {
    private let title: String
    private let shortcut: String?

    /// Control Center's footer rows (Sound Settings…): 22 pt.
    static let height: CGFloat = 22

    init(title: String, shortcut: String?, onPick: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        super.init(height: Self.height, accessibilityTitle: title, onPick: onPick)
        sizeToContent()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static let shortcutAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.tertiaryLabelColor,
    ]

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: Self.titleAttributes).width
        let key = shortcut.map { ($0 as NSString).size(withAttributes: Self.shortcutAttributes).width + 24 } ?? 0
        return NSSize(width: Self.contentInset + text + key + 24, height: Self.height)
    }

    override func drawContent(in bounds: NSRect) {
        let size = (title as NSString).size(withAttributes: Self.titleAttributes)
        (title as NSString).draw(at: NSPoint(x: Self.contentInset, y: (bounds.height - size.height) / 2),
                                 withAttributes: Self.titleAttributes)
        if let shortcut {
            let s = (shortcut as NSString).size(withAttributes: Self.shortcutAttributes)
            (shortcut as NSString).draw(at: NSPoint(x: bounds.maxX - Self.contentInset - s.width,
                                                    y: (bounds.height - s.height) / 2),
                                        withAttributes: Self.shortcutAttributes)
        }
    }
}

/// A server in the Servers list: its round mark and its name, and a click
/// that switches without closing the menu, as the Sound menu's outputs do.
/// The one in use carries a chevron, as the AirPods in use do: a click
/// opens its stream settings under it, and the chevron turns from right to
/// down with the rows (MenuDisclosureList sets `disclosureProgress`).
///
/// Laid out as the Sound menu's AirPods row, measured at 2x off Kevin's
/// recording (2026-11-18): a 32 pt row - two lines or one - the 26 pt disc
/// 14 pt in, the name 8 pt after it; with a second line, the name's
/// baseline 14.5 pt from the top and the line's 28.5 pt, the line in 11 pt
/// secondary grey with a solid glyph before each value, its ink 10 pt tall
/// and centred on the figures, 6 pt from glyph to figure and 10.5 pt from
/// figure to the next glyph. The chevron's ink 18.5 pt in from the right.
final class MenuServerRow: MenuRowView {
    /// One value on the second line: its glyph (an SF Symbol) and text.
    struct Stat: Equatable {
        var symbol: String?
        var text: String
    }

    private let title: String
    private let mark: NSImage
    let hasDisclosure: Bool

    /// The chevron's turn: 0 points right (closed), 1 points down (open).
    /// Driven by the disclosure's spring, so it overshoots a touch with it.
    var disclosureProgress: CGFloat = 0 {
        didSet {
            guard disclosureProgress != oldValue else { return }
            redrawContent()
        }
    }

    /// The second line, as the AirPods' batteries sit under their name: the
    /// server streaming now shows the stream's numbers there, refreshed
    /// while the menu is open. Empty: one line.
    var stats: [Stat] = [] {
        didSet {
            guard stats != oldValue else { return }
            redrawContent()
            setAccessibilityValue(stats.isEmpty ? nil : stats.map(\.text).joined(separator: ", "))
        }
    }

    static let height: CGFloat = 32
    private static let discX: CGFloat = MenuRowView.contentInset
    private static let textX: CGFloat = MenuRowView.contentInset + MenuHostMark.diameter + 8

    init(title: String, mark: NSImage, hasDisclosure: Bool = false, onPick: @escaping () -> Void) {
        self.title = title
        self.mark = mark
        self.hasDisclosure = hasDisclosure
        super.init(height: Self.height, accessibilityTitle: title, onPick: onPick)
        if hasDisclosure { setAccessibilityExpanded(false) }
        sizeToContent()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Wide enough for the name and its line, so the menu sizes itself
    /// around them.
    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: Self.titleAttributes).width
        return NSSize(width: Self.textX + max(text, statsWidth) + (hasDisclosure ? 40 : 20), height: Self.height)
    }

    // MARK: Drawing

    static let statFont = NSFont.systemFont(ofSize: 11)
    private static var statAttributes: [NSAttributedString.Key: Any] {
        [.font: statFont, .foregroundColor: NSColor.secondaryLabelColor]
    }

    /// A text's ink, from its drawing origin: where the first glyph's ink
    /// starts and how wide it runs.
    private static func ink(of text: String) -> (left: CGFloat, width: CGFloat) {
        let bounds = NSAttributedString(string: text, attributes: [.font: statFont])
            .boundingRect(with: .zero, options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
        return (bounds.minX, bounds.width)
    }

    var statsWidth: CGFloat {
        var x: CGFloat = 1
        for (i, stat) in stats.enumerated() {
            if i > 0 { x += 10.5 }
            if let symbol = stat.symbol, let glyph = MenuStatGlyph.image(symbol) { x += glyph.size.width + 6 }
            x += Self.ink(of: stat.text).width
        }
        return x
    }

    override func drawContent(in bounds: NSRect) {
        let d = MenuHostMark.diameter
        mark.draw(in: NSRect(x: Self.discX, y: ((bounds.height - d) / 2).rounded(), width: d, height: d))
        let font = Self.titleAttributes[.font] as? NSFont ?? .menuFont(ofSize: 0)
        if stats.isEmpty {
            let size = (title as NSString).size(withAttributes: Self.titleAttributes)
            (title as NSString).draw(at: NSPoint(x: Self.textX, y: (bounds.height - size.height) / 2),
                                     withAttributes: Self.titleAttributes)
        } else {
            // Baselines 14.5 and 28.5 pt down from the row's top.
            (title as NSString).draw(at: NSPoint(x: Self.textX, y: bounds.maxY - 14.5 + font.descender),
                                     withAttributes: Self.titleAttributes)
            drawStats(baseline: bounds.maxY - 28.5)
        }
        if hasDisclosure { drawChevron(in: bounds) }
    }

    private func drawStats(baseline: CGFloat) {
        let font = Self.statFont
        // The glyphs' ink centred on the figures' (their cap height's middle).
        let middle = baseline + font.capHeight / 2
        // The first glyph's ink under the name's first letter.
        var x = Self.textX + 1
        for (i, stat) in stats.enumerated() {
            if i > 0 { x += 10.5 }
            if let symbol = stat.symbol, let glyph = MenuStatGlyph.image(symbol) {
                let s = glyph.size
                MenuStatGlyph.draw(glyph, in: NSRect(x: x, y: middle - s.height / 2, width: s.width, height: s.height),
                                   colour: .secondaryLabelColor)
                x += s.width + 6
            }
            let ink = Self.ink(of: stat.text)
            (stat.text as NSString).draw(at: NSPoint(x: x - ink.left, y: baseline + font.descender),
                                         withAttributes: Self.statAttributes)
            x += ink.width
        }
    }

    private static let chevron: NSImage? = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(.init(paletteColors: [.secondaryLabelColor])))

    private func drawChevron(in bounds: NSRect) {
        guard let chevron = Self.chevron else { return }
        // The Sound menu's chevron: one glyph, turned about its centre -
        // right when closed, down when open (clockwise, as it opens). Its
        // ink 18.5 pt in from the right and half a point below the row's
        // middle, as measured.
        let s = chevron.size
        let centre = NSPoint(x: bounds.maxX - 17.5 - s.width / 2,
                             y: ((bounds.height - s.height) / 2).rounded() + s.height / 2 - 1)
        NSGraphicsContext.saveGraphicsState()
        let turn = NSAffineTransform()
        turn.translateX(by: centre.x, yBy: centre.y)
        turn.rotate(byDegrees: -90 * disclosureProgress)
        turn.concat()
        chevron.draw(in: NSRect(x: -s.width / 2, y: -s.height / 2, width: s.width, height: s.height))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The small solid glyphs of a server's second line, cut to their ink and
/// sized to the AirPods' (10 pt tall), so every glyph sits exactly where
/// the measurements put it whatever padding its symbol carries.
@MainActor
enum MenuStatGlyph {
    static let inkHeight: CGFloat = 10
    private static var cache: [String: NSImage] = [:]

    static func image(_ symbol: String) -> NSImage? {
        if let cached = cache[symbol] { return cached }
        guard let source = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 80, weight: .regular)),
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where data[(y * w + x) * 4 + 3] > 16 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        // Bitmap memory runs top down, as CGImage cropping counts.
        guard maxX >= minX, let cropped = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1,
                                                                   height: maxY - minY + 1)) else { return nil }
        let scale = inkHeight / CGFloat(cropped.height)
        let image = NSImage(cgImage: cropped, size: NSSize(width: CGFloat(cropped.width) * scale, height: inkHeight))
        cache[symbol] = image
        return image
    }

    /// Drawn in a dynamic colour: the glyph filled opaque in the colour,
    /// then laid down at the colour's alpha - a translucent fill over the
    /// black artwork would leave the black showing.
    static func draw(_ glyph: NSImage, in rect: NSRect, colour: NSColor) {
        let resolved = colour.usingColorSpace(.sRGB) ?? colour
        let opaque = resolved.withAlphaComponent(1)
        let tinted = NSImage(size: rect.size, flipped: false) { r in
            glyph.draw(in: r)
            opaque.setFill()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: resolved.alphaComponent)
    }
}

/// Control Center's separator: a 1 pt line in the separator grey, 10 pt of
/// row with the line 5.75 pt down - measured off the Sound menu at 2x
/// (2026-11-18), where NSMenu's own sits taller and 2 pt further in.
final class MenuSeparatorRow: NSView {
    private let inset: CGFloat

    init(inset: CGFloat) {
        self.inset = inset
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 10))
        autoresizingMask = [.width]
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        // 5.75 pt from the top, in this unflipped view.
        NSRect(x: inset, y: bounds.height - 6.25, width: bounds.width - inset * 2, height: 1).fill()
    }
}

/// Control Center's section header ("Output" in the Sound menu): 12 pt
/// semibold in the secondary grey, 14 pt in, its baseline 16.75 pt down a
/// 23 pt row - measured at 2x (2026-11-18). NSMenu's own is 11 pt in the
/// tertiary grey, 2 pt further in.
final class MenuSectionHeaderRow: NSView {
    private let title: String

    static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
    ]
    static let height: CGFloat = 23
    static let baseline: CGFloat = 16.75

    init(_ title: String, height: CGFloat = MenuSectionHeaderRow.height) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: height))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let font = Self.attributes[.font] as? NSFont ?? .systemFont(ofSize: 12)
        // draw(at:) takes the top of the line box in a flipped view.
        (title as NSString).draw(at: NSPoint(x: MenuRowView.contentInset, y: Self.baseline - font.ascender),
                                 withAttributes: Self.attributes)
    }
}

// MARK: - The server in use's stream settings (its chevron)

/// A setting as a row of text segments - the stock segmented control, full
/// width, lined up with the section titles. Text, not icons: a choice of
/// resolutions has no honest pictures, so the Sound menu's iconned
/// Listening Mode list doesn't carry over (Kevin picked this, 2026-11-18,
/// from real mock-ups in design/menu-bar).
final class MenuSegmentRow: NSView {
    private let control: NSSegmentedControl
    private let onChange: (Int) -> Void

    init(labels: [String], selected: Int?, accessibilityTitle: String, onChange: @escaping (Int) -> Void) {
        control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 30))
        autoresizingMask = [.width]
        control.selectedSegment = selected ?? -1
        control.segmentDistribution = .fillEqually
        control.target = self
        control.action = #selector(changed)
        control.setAccessibilityLabel(accessibilityTitle)
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuRowView.contentInset),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuRowView.contentInset),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func changed() {
        guard control.selectedSegment >= 0 else { return }
        onChange(control.selectedSegment)
    }
}

/// Bitrate as a slider: "Auto" at its left end (the stop before the
/// lowest), what it asks for at the right - the number Automatic works out
/// to, or the one set.
final class MenuBitrateRow: NSView {
    private let slider = NSSlider()
    private let value = NSTextField(labelWithString: "")
    private let stops: [Int]
    private let autoMbps: Int?
    private let onChange: (Int?) -> Void
    private var index: Int

    /// `mbps` nil: automatic. `onChange` gets nil for automatic.
    init(stops: [Int], mbps: Int?, autoMbps: Int?, onChange: @escaping (Int?) -> Void) {
        self.stops = stops
        self.autoMbps = autoMbps
        self.onChange = onChange
        index = mbps.map { m in 1 + (stops.indices.min { abs(stops[$0] - m) < abs(stops[$1] - m) } ?? 0) } ?? 0
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 30))
        autoresizingMask = [.width]
        let auto = NSTextField(labelWithString: "Auto")
        for label in [auto, value] {
            label.font = .menuFont(ofSize: 0)
            label.textColor = .secondaryLabelColor
        }
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        value.alignment = .right
        slider.minValue = 0
        slider.maxValue = Double(stops.count)
        // Stepped, but without tick marks - they cluttered a menu row; the
        // knob snaps to the stop instead (`moved`).
        slider.doubleValue = Double(index)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)
        slider.setAccessibilityLabel("Bitrate")
        for view in [auto, slider, value] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // The value's width fixed to its widest, so the slider holds still.
        let widest = ("300 Mbps" as NSString).size(withAttributes: [.font: value.font!]).width + 2
        NSLayoutConstraint.activate([
            auto.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuRowView.contentInset),
            auto.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: auto.trailingAnchor, constant: 8),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            value.widthAnchor.constraint(equalToConstant: widest),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuRowView.contentInset),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        showValue()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func showValue() {
        if index == 0 {
            value.stringValue = autoMbps.map { "\($0) Mbps" } ?? "Auto"
        } else {
            value.stringValue = "\(stops[index - 1]) Mbps"
        }
    }

    @objc private func moved() {
        let new = Int(slider.doubleValue.rounded())
        slider.doubleValue = Double(new)
        guard new != index else { return }
        index = new
        showValue()
        onChange(index == 0 ? nil : stops[index - 1])
    }
}

/// A line of small grey text under a setting.
final class MenuNoteRow: NSView {
    private let text: String

    init(_ text: String) {
        self.text = text
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 22))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        (text as NSString).draw(at: NSPoint(x: MenuRowView.contentInset, y: 5), withAttributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }
}
