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

/// A flat tint over the menu's glass, laid down the way Control Center
/// lays its own: in the dark it adds a fixed amount of light to whatever
/// the glass shows (a hovered row and the AirPods' opened band both read
/// +21 of 255 on every backdrop measured - additive, not a white wash,
/// which would add less over a lighter backdrop); in the light it darkens.
class MenuTintView: NSView {
    enum Tint {
        /// A hovered row.
        case hover
        /// The band a server opens under it.
        case band
        /// A hairline inside the band.
        case bandDivider
        /// A segmented switcher's track, its selected segment (over the
        /// track) and the hairline between two unselected ones.
        case segmentTrack, segmentSelected, segmentDivider
    }

    var tint: Tint = .hover { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let colour: NSColor
        switch (tint, dark) {
        case (.hover, true), (.band, true): colour = NSColor(white: 1, alpha: 21.0 / 255)
        case (.bandDivider, true): colour = NSColor(white: 1, alpha: 20.0 / 255)
        case (.hover, false): colour = NSColor(white: 0, alpha: 0.075)
        case (.band, false): colour = NSColor(white: 0, alpha: 0.045)
        case (.bandDivider, false): colour = NSColor(white: 0, alpha: 0.10)
        case (.segmentTrack, true), (.segmentSelected, true): colour = NSColor(white: 1, alpha: 26.0 / 255)
        case (.segmentDivider, true): colour = NSColor(white: 1, alpha: 0.2)
        case (.segmentTrack, false): colour = NSColor(white: 0, alpha: 0.07)
        case (.segmentSelected, false): colour = NSColor(white: 0, alpha: 0.14)
        case (.segmentDivider, false): colour = NSColor(white: 0, alpha: 0.26)
        }
        layer?.backgroundColor = colour.cgColor
        // Core Animation's additive blend, by its filter name.
        layer?.compositingFilter = dark ? "plusL" : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // Never in the way of a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The menu's text greys, measured off the Sound menu at native 2x in the
/// dark (Kevin's MacBook, 2026-11-18): how much of the way to white each
/// ink goes over the glass. Apple's menu text isn't the system label
/// colours - its names are brighter (90% against labelColor's 85%) and its
/// second lines, headers and chevrons dimmer (45% and 41% against
/// secondaryLabelColor's 55%), so with the system colours a server's
/// second line read bigger and heavier than the AirPods' batteries in the
/// same 11 pt. Light mode keeps the system values: not measured.
enum MenuInk {
    /// A row's name, a control's label.
    static let primary = ink(dark: 0.90, light: 0.85)
    /// A row's second line (the AirPods' batteries, a server's status).
    static let secondary = ink(dark: 0.45, light: 0.50)
    /// Section headers and the disclosure chevron.
    static let header = ink(dark: 0.41, light: 0.50)

    private static func ink(dark: CGFloat, light: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: dark) : NSColor(white: 0, alpha: light)
        }
    }
}

/// A line of text with its baseline exactly where asked. NSString's
/// draw(at:) places the line's box, and the baseline lands wherever the
/// font's metrics and pixel snapping put it (a 12 pt header came out a
/// point low); Control Center's spacing is measured baseline to baseline.
enum MenuText {
    /// `baseline`: the baseline's y in the current view; `flipped`: the view's.
    static func draw(_ text: String, font: NSFont, colour: NSColor, x: CGFloat, baseline: CGFloat, flipped: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let string = NSAttributedString(string: text, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(string)
        context.saveGState()
        colour.setFill()
        context.textMatrix = flipped ? CGAffineTransform(scaleX: 1, y: -1) : .identity
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
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

    /// The hover band: the Sound menu's, measured at native 2x on the
    /// MacBook (2026-11-18) - the row's full height, 5 pt in from each
    /// side of the menu, corners 10 pt (7 pt on the short footer rows).
    private final class HoverFill: MenuTintView {
        override func layout() {
            super.layout()
            layer?.cornerRadius = bounds.height >= 30 ? 10 : 7
        }
    }

    /// Control Center's content inset: where discs, titles, headers and
    /// separators start, from either side of the row.
    static let contentInset: CGFloat = 14

    /// How far the hover band stops short of the menu's sides.
    static let hoverInset: CGFloat = 5

    init(height: CGFloat, accessibilityTitle: String, onPick: @escaping () -> Void) {
        self.onPick = onPick
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: height))
        autoresizingMask = [.width]

        hover.isHidden = true
        hover.tint = .hover
        hover.frame = bounds.insetBy(dx: Self.hoverInset, dy: 0)
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
        .font: NSFont.menuFont(ofSize: 0), .foregroundColor: MenuInk.primary,
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
/// Laid out as the Sound menu's AirPods row, measured at native 2x on
/// Kevin's MacBook (2026-11-18): a 32 pt row - two lines or one - the 26 pt
/// disc 14 pt in, the name 8 pt after it; with a second line, the name's
/// baseline 14 pt from the top and the line's 28 pt, the line in 11 pt
/// secondary grey with a solid glyph before each value, its ink 9.5 pt tall
/// and centred on the figures, 6.5 pt from glyph to figure and 10.5 pt from
/// figure to the next glyph. The chevron's ink 18 pt in from the right.
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


    /// A text's ink, from its drawing origin: where the first glyph's ink
    /// starts and how wide it runs.
    private static func ink(of text: String) -> (left: CGFloat, width: CGFloat) {
        let bounds = NSAttributedString(string: text, attributes: [.font: statFont])
            .boundingRect(with: .zero, options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
        return (bounds.minX, bounds.width)
    }

    var statsWidth: CGFloat {
        var x: CGFloat = 1.5
        for (i, stat) in stats.enumerated() {
            if i > 0 { x += 10.5 }
            if let symbol = stat.symbol, let glyph = MenuStatGlyph.image(symbol) { x += glyph.size.width + 6.5 }
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
            // Baselines 14 and 28 pt down from the row's top.
            MenuText.draw(title, font: font, colour: MenuInk.primary, x: Self.textX, baseline: bounds.maxY - 14,
                          flipped: false)
            drawStats(baseline: bounds.maxY - 28)
        }
        if hasDisclosure { drawChevron(in: bounds) }
    }

    private func drawStats(baseline: CGFloat) {
        let font = Self.statFont
        // The glyphs' ink centred on the figures' (their cap height's middle).
        let middle = baseline + font.capHeight / 2
        // The first glyph's ink under the name's first letter.
        var x = Self.textX + 1.5
        for (i, stat) in stats.enumerated() {
            if i > 0 { x += 10.5 }
            if let symbol = stat.symbol, let glyph = MenuStatGlyph.image(symbol) {
                let s = glyph.size
                MenuStatGlyph.draw(glyph, in: NSRect(x: x, y: middle - s.height / 2, width: s.width, height: s.height),
                                   colour: MenuInk.secondary)
                x += s.width + 6.5
            }
            let ink = Self.ink(of: stat.text)
            MenuText.draw(stat.text, font: font, colour: MenuInk.secondary, x: x - ink.left, baseline: baseline,
                          flipped: false)
            x += ink.width
        }
    }

    /// The chevron's ink alone, 10 pt tall (6 pt wide), as the Sound menu's.
    private static let chevron = MenuStatGlyph.image("chevron.right", inkHeight: 10, weight: .medium)

    private func drawChevron(in bounds: NSRect) {
        guard let chevron = Self.chevron else { return }
        // The Sound menu's chevron, measured at native 2x: one glyph turned
        // a quarter (clockwise as it opens) about a point 21 pt in from the
        // right on the row's middle, its ink centred half a point under
        // that point - so closed it sits half a point low, and open half a
        // point left.
        let s = chevron.size
        NSGraphicsContext.saveGraphicsState()
        let turn = NSAffineTransform()
        turn.translateX(by: bounds.maxX - 21, yBy: bounds.midY)
        turn.rotate(byDegrees: -90 * disclosureProgress)
        turn.concat()
        MenuStatGlyph.draw(chevron, in: NSRect(x: -s.width / 2, y: -s.height / 2 - 0.5, width: s.width, height: s.height),
                           colour: MenuInk.header)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The small solid glyphs of a server's second line, cut to their ink and
/// sized to the AirPods' (9.5 pt tall), so every glyph sits exactly where
/// the measurements put it whatever padding its symbol carries.
@MainActor
enum MenuStatGlyph {
    static let inkHeight: CGFloat = 9.5
    private static var cache: [String: NSImage] = [:]

    static func image(_ symbol: String, inkHeight: CGFloat = MenuStatGlyph.inkHeight,
                      weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(symbol) \(inkHeight)"
        if let cached = cache[key] { return cached }
        guard let source = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 80, weight: weight)),
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
        cache[key] = image
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
/// row with the line 5 pt down (on the pixel grid at 2x) - measured off the
/// Sound menu at native 2x (2026-11-18), where NSMenu's own sits taller and
/// 2 pt further in.
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
        // Its top 5 pt down, in this unflipped view.
        NSRect(x: inset, y: bounds.height - 6, width: bounds.width - inset * 2, height: 1).fill()
    }
}

/// Control Center's section header ("Output" in the Sound menu): 12 pt
/// semibold in the secondary grey, 14 pt in, its baseline 16.5 pt down a
/// 23 pt row - measured at native 2x (2026-11-18). NSMenu's own is 11 pt in
/// the tertiary grey, 2 pt further in.
final class MenuSectionHeaderRow: NSView {
    private let title: String

    static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let height: CGFloat = 23
    /// The title's baseline, from the row's top: 21.5 pt under the
    /// separator line's top and 9.5 pt above the first disc, as "Output"
    /// sits.
    static let baseline: CGFloat = 16.5

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
        MenuText.draw(title, font: Self.font, colour: MenuInk.header, x: MenuRowView.contentInset,
                      baseline: Self.baseline, flipped: true)
    }
}

/// A setting as a row of text segments, full width, lined up with the
/// section titles. Text, not icons: a choice of resolutions has no honest
/// pictures, so the Sound menu's iconned Listening Mode list doesn't carry
/// over (Kevin picked this, 2026-11-18, from real mock-ups in
/// design/menu-bar).
///
/// Drawn here, in the flat look he picked: the stock segmented control
/// looked that way only inside an NSMenu, whose window is never the key
/// one - in the menu's panel (MenuBarPanel, which takes the keyboard) it
/// fills its selected segment with the accent colour. Measured off the
/// stock control at native 2x: a 24 pt track with 6 pt corners, tinted one
/// step over the band; the selected segment one step more; a short hairline
/// between two segments neither of which is selected.
final class MenuSegmentRow: NSView {
    private let labels: [String]
    private let onChange: (Int) -> Void
    private(set) var selected: Int?

    private let track = MenuTintView()
    private let pill = MenuTintView()
    private var dividers: [MenuTintView] = []
    private let text = Labels()
    private var segments: [Segment] = []

    private static let trackHeight: CGFloat = 24
    private static let radius: CGFloat = 6
    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    init(labels: [String], selected: Int?, accessibilityTitle: String, onChange: @escaping (Int) -> Void) {
        self.labels = labels
        self.selected = selected.flatMap { labels.indices.contains($0) ? $0 : nil }
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 30))
        autoresizingMask = [.width]
        track.tint = .segmentTrack
        pill.tint = .segmentSelected
        for view in [track, pill] {
            view.layer?.cornerRadius = Self.radius
            addSubview(view)
        }
        for _ in labels.dropFirst() {
            let divider = MenuTintView()
            divider.tint = .segmentDivider
            dividers.append(divider)
            addSubview(divider)
        }
        text.row = self
        addSubview(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(accessibilityTitle)
        segments = labels.indices.map { Segment(row: self, index: $0) }
        setAccessibilityChildren(segments)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var trackFrame: NSRect {
        NSRect(x: MenuRowView.contentInset, y: ((bounds.height - Self.trackHeight) / 2).rounded(),
               width: bounds.width - MenuRowView.contentInset * 2, height: Self.trackHeight)
    }

    fileprivate func segmentFrame(_ index: Int) -> NSRect {
        let t = trackFrame, count = CGFloat(labels.count)
        let left = (t.minX + t.width * CGFloat(index) / count).rounded()
        let right = (t.minX + t.width * CGFloat(index + 1) / count).rounded()
        return NSRect(x: left, y: t.minY, width: right - left, height: t.height)
    }

    override func layout() {
        super.layout()
        track.frame = trackFrame
        text.frame = bounds
        pill.isHidden = selected == nil
        if let selected { pill.frame = segmentFrame(selected) }
        for (i, divider) in dividers.enumerated() {
            // Between segments i and i+1, unless one of them is selected.
            divider.isHidden = selected == i || selected == i + 1
            divider.frame = NSRect(x: segmentFrame(i).maxX - 0.5, y: trackFrame.midY - 7, width: 1, height: 14)
        }
        text.needsDisplay = true
    }

    private func select(_ index: Int) {
        guard labels.indices.contains(index), index != selected else { return }
        selected = index
        needsLayout = true
        onChange(index)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard trackFrame.contains(point) else { return }
        if let index = labels.indices.first(where: { segmentFrame($0).contains(point) }) { select(index) }
    }

    /// The titles, over the tints.
    private final class Labels: NSView {
        weak var row: MenuSegmentRow?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let row else { return }
            let font = MenuSegmentRow.font
            for (i, label) in row.labels.enumerated() {
                let frame = row.segmentFrame(i)
                let width = (label as NSString).size(withAttributes: [.font: font]).width
                // The capitals centred on the track.
                MenuText.draw(label, font: font, colour: MenuInk.primary, x: (frame.midX - width / 2).rounded(),
                              baseline: (frame.midY + font.capHeight / 2).rounded(), flipped: true)
            }
        }
    }

    /// One segment, for VoiceOver: a radio button in the row's group.
    private final class Segment: NSAccessibilityElement {
        private weak var row: MenuSegmentRow?
        private let index: Int

        init(row: MenuSegmentRow, index: Int) {
            self.row = row
            self.index = index
            super.init()
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(row.labels[index])
            setAccessibilityParent(row)
        }

        override func accessibilityValue() -> Any? { row?.selected == index ? 1 : 0 }

        override func accessibilityFrame() -> NSRect {
            guard let row, let window = row.window else { return .zero }
            return window.convertToScreen(row.convert(row.segmentFrame(index), to: nil))
        }

        override func accessibilityPerformPress() -> Bool {
            row?.select(index)
            return row != nil
        }
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
            label.textColor = MenuInk.secondary
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
            .foregroundColor: MenuInk.secondary,
        ])
    }
}
