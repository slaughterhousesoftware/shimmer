//
//  MenuNowPlaying.swift
//
//  The top of the menu bar menu: macOS's Now Playing card (Control Center),
//  for a stream - the app's tile, what it is and where, and the two
//  controls at the right. Kevin's pick from five real mock-ups
//  (design/menu-bar/top-3.png, 2026-11-18: "easily the best option").
//
//  Ready:     [tile] Steam Big Picture / bazzite        (PiP) (Play)
//  Streaming: [tile] Steam Big Picture / Streaming from  (PiP) (Stop)
//
//  Geometry is the mock-up's: a 60 pt card inset 12 x 6 in its row, 14 pt
//  corners, a 42 pt tile, 30 pt round buttons 38 pt apart - in line with
//  Control Center's own round buttons (26 pt in a row, 38 pt prominent,
//  per MacControlCenterUI's measurements).
//

import AppKit

final class MenuNowPlayingCard: NSView {
    struct Control {
        var symbol: String
        var label: String
        /// The blue one: the action the card is for.
        var prominent = false
        var action: () -> Void
    }

    private let tile: NSImage
    private let title: String
    private let subtitle: String
    private let onOpen: (() -> Void)?
    private var buttons: [MenuRoundButton] = []
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    static let height: CGFloat = 72
    private static let inset = NSSize(width: 12, height: 6)
    private static let buttonSide: CGFloat = 30, buttonPitch: CGFloat = 38

    /// `onOpen`: a click on the card itself (not its buttons) - the way back
    /// to a stream that is out of sight, as clicking Now Playing opens the app.
    init(tile: NSImage, title: String, subtitle: String, controls: [Control], onOpen: (() -> Void)? = nil) {
        self.tile = tile
        self.title = title
        self.subtitle = subtitle
        self.onOpen = onOpen
        super.init(frame: NSRect(x: 0, y: 0, width: 307, height: Self.height))
        autoresizingMask = [.width]
        for control in controls {
            let button = MenuRoundButton(symbol: control.symbol, label: control.label, prominent: control.prominent,
                                         action: control.action)
            buttons.append(button)
            addSubview(button)
        }
        // Wide enough for its two lines, up to a point (they truncate past that).
        let text = max((title as NSString).size(withAttributes: Self.titleAttributes).width,
                       (subtitle as NSString).size(withAttributes: Self.subtitleAttributes).width)
        let needed = Self.inset.width * 2 + 10 + 42 + 10 + text + 12 + CGFloat(controls.count) * Self.buttonPitch + 4
        setFrameSize(NSSize(width: min(max(307, needed.rounded(.up)), 380), height: Self.height))
        setAccessibilityElement(true)
        setAccessibilityRole(onOpen == nil ? .group : .button)
        setAccessibilityLabel("\(title), \(subtitle)")
        layoutButtons()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var card: NSRect { bounds.insetBy(dx: Self.inset.width, dy: Self.inset.height) }

    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutButtons() }

    private func layoutButtons() {
        let side = Self.buttonSide
        // The last control rightmost, as Now Playing's play button.
        for (i, button) in buttons.reversed().enumerated() {
            let x = card.maxX - 26 - CGFloat(i) * Self.buttonPitch
            button.frame = NSRect(x: (x - side / 2).rounded(), y: (card.midY - side / 2).rounded(), width: side, height: side)
        }
    }

    static let titleAttributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: MenuInk.primary,
                .paragraphStyle: style]
    }()

    static let subtitleAttributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: MenuInk.secondary,
                .paragraphStyle: style]
    }()

    /// The card's grey darkens what the menu's glass shows, as the system's do.
    override var allowsVibrancy: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let card = card
        NSColor.labelColor.withAlphaComponent(isHovered ? 0.08 : 0.05).setFill()
        NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
        tile.draw(in: NSRect(x: card.minX + 10, y: (card.midY - 21).rounded(), width: 42, height: 42))
        let textX = card.minX + 62
        let textWidth = (buttons.map(\.frame.minX).min() ?? card.maxX) - 10 - textX
        let titleHeight = (title as NSString).size(withAttributes: Self.titleAttributes).height
        let subtitleHeight = (subtitle as NSString).size(withAttributes: Self.subtitleAttributes).height
        (title as NSString).draw(with: NSRect(x: textX, y: card.midY + 1, width: textWidth, height: titleHeight),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: Self.titleAttributes)
        (subtitle as NSString).draw(with: NSRect(x: textX, y: card.midY - 15, width: textWidth, height: subtitleHeight),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: Self.subtitleAttributes)
    }

    // MARK: The card itself as a button (only when it has somewhere to go)

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard onOpen != nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func overCard(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return card.contains(point) && !buttons.contains { $0.frame.contains(point) }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = overCard(event) }
    override func mouseMoved(with event: NSEvent) { isHovered = overCard(event) }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        guard let onOpen, overCard(event) else { return }
        onOpen()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onOpen else { return false }
        onOpen()
        return true
    }
}

/// Control Center's round button: a filled circle and its glyph - grey, or
/// the accent colour for the one the card is for - darker while pressed.
final class MenuRoundButton: NSView {
    private let symbol: String
    private let prominent: Bool
    private let action: () -> Void
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }

    init(symbol: String, label: String, prominent: Bool, action: @escaping () -> Void) {
        self.symbol = symbol
        self.prominent = prominent
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var allowsVibrancy: Bool { !prominent }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor = prominent
            ? (isPressed ? NSColor.controlAccentColor.blended(withFraction: 0.2, of: .black) ?? .controlAccentColor
                         : .controlAccentColor)
            : NSColor.labelColor.withAlphaComponent(isPressed ? 0.18 : 0.09)
        fill.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let ink: NSColor = prominent ? .white : .labelColor
        let config = NSImage.SymbolConfiguration(pointSize: bounds.height * 0.42, weight: .semibold)
            .applying(.init(paletteColors: [ink]))
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        else { return }
        let s = glyph.size
        glyph.draw(in: NSRect(x: ((bounds.width - s.width) / 2).rounded(), y: ((bounds.height - s.height) / 2).rounded(),
                              width: s.width, height: s.height))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

/// An app's tile for the card: its mark in white on a rounded square of its
/// own colour - Steam on its navy, a PlayStation on PlayStation blue, the
/// rest on a hue of their own (LibraryApp.iconHue). The mark is centred by
/// its measured ink and sized by the sidebar's rule (HostAvatar.glyphFrame),
/// as the Servers marks are.
enum MenuAppTile {
    static let side: CGFloat = 42

    enum Kind {
        case app(LibraryApp?)
        case playStation
        case shimmer
    }

    static func image(_ kind: Kind) -> NSImage {
        if case .shimmer = kind, let icon = NSApp?.applicationIconImage {
            return icon
        }
        let (colours, mark) = art(kind)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let plate = NSBezierPath(roundedRect: rect, xRadius: side * 0.24, yRadius: side * 0.24)
            NSGradient(colors: colours)?.draw(in: plate, angle: -60)
            guard let mark else { return true }
            draw(mark, centredByInkIn: rect)
            return true
        }
    }

    private static func art(_ kind: Kind) -> ([NSColor], NSImage?) {
        switch kind {
        case .playStation:
            return ([rgb(0x00439C), rgb(0x0070D1)], symbol("playstation.logo"))
        case .app(let app):
            guard let app else { return ([rgb(0x5B6573), rgb(0x8A94A3)], symbol("display")) }
            switch app.glyph {
            case .asset(let name) where name == "SteamGlyph":
                return ([rgb(0x1A2945), rgb(0x0D548C)], NSImage(named: name))
            case .asset(let name):
                return (hued(app.iconHue), NSImage(named: name))
            case .symbol(let name) where name == "display" || name == "desktopcomputer":
                return ([rgb(0x5B6573), rgb(0x8A94A3)], symbol(name))
            case .symbol(let name):
                return (hued(app.iconHue), symbol(name))
            }
        case .shimmer:
            return ([rgb(0x5B6573), rgb(0x8A94A3)], nil)
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 64, weight: .regular))
    }

    private static func hued(_ hue: Double) -> [NSColor] {
        [NSColor(hue: hue, saturation: 0.62, brightness: 0.48, alpha: 1),
         NSColor(hue: hue, saturation: 0.55, brightness: 0.72, alpha: 1)]
    }

    private static func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    /// The mark in white, its ink box (not its frame - symbols carry
    /// padding) centred on the tile and sized by HostAvatar.glyphFrame.
    private static func draw(_ mark: NSImage, centredByInkIn rect: NSRect) {
        let px = 256
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = mark.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let aspect = mark.size.width / max(mark.size.height, 1)
        let fit = aspect >= 1 ? CGSize(width: CGFloat(px), height: CGFloat(px) / aspect)
                              : CGSize(width: CGFloat(px) * aspect, height: CGFloat(px))
        let placed = CGRect(x: (CGFloat(px) - fit.width) / 2, y: (CGFloat(px) - fit.height) / 2,
                            width: fit.width, height: fit.height)
        ctx.draw(cg, in: placed)
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return }
        var minX = px, minY = px, maxX = -1, maxY = -1
        for y in 0..<px {
            for x in 0..<px where data[(y * px + x) * 4 + 3] > 24 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return }
        // Bitmap rows run top down; the ink box in the fitted art's units.
        let ink = CGRect(x: CGFloat(minX), y: CGFloat(px - 1 - maxY), width: CGFloat(maxX - minX + 1),
                         height: CGFloat(maxY - minY + 1))
        let size = HostAvatar.glyphFrame(aspect: ink.width / max(ink.height, 1), size: rect.width)
        let k = min(size.width / ink.width, size.height / ink.height)
        let scaled = CGRect(x: placed.minX * k, y: placed.minY * k, width: placed.width * k, height: placed.height * k)
        let origin = NSPoint(x: rect.midX - (ink.midX * k), y: rect.midY - (ink.midY * k))
        let white = NSImage(size: scaled.size, flipped: false) { r in
            mark.draw(in: r)
            NSColor.white.setFill()
            r.fill(using: .sourceAtop)
            return true
        }
        white.draw(in: NSRect(x: origin.x + scaled.minX, y: origin.y + scaled.minY,
                              width: scaled.width, height: scaled.height))
    }
}
