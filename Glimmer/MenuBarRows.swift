//
//  MenuBarRows.swift
//
//  The menu bar menu's custom rows: the Sound menu's volume slider, copied
//  (a quiet speaker, the slider, a loud speaker, nothing else - Kevin,
//  2026-11-18: "just copy this"), and the Servers list - each machine's
//  Settings avatar on a round disc, in colour for the one in use, as
//  Control Center's Focus and Sound lists mark the one that's on.
//

import AppKit
import SwiftUI

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

/// A server's round mark for its menu row - the Settings sidebar's avatar
/// (HostAvatar: the PlayStation blue, Bazzite's gradient, a distro's colour),
/// drawn the way Control Center's lists (Focus, Sound, Wi-Fi) draw a row's
/// disc: in colour for the one that's on, grey with a dark mark for the rest.
/// Rendered from HostAvatar.disc itself, so the marks are sized and centred
/// exactly as in Settings.
@MainActor
enum MenuHostMark {
    static let diameter: CGFloat = 26

    enum Look: String { case current, off, offHighlighted }

    private static var cache: [String: NSImage] = [:]

    static func image(for host: Host, look: Look, appearance: NSAppearance) -> NSImage {
        let mark = HostAvatar.mark(for: host)
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let key = "\(mark)|\(look.rawValue)|\(dark)|\(scale)"
        if let cached = cache[key] { return cached }

        let disc: AnyView
        switch look {
        case .current:
            disc = AnyView(HostAvatar.disc(mark, size: diameter))
        case .off:
            // The system's grey fill and text colour, resolved for the
            // menu's appearance (the picture is drawn once, not live).
            var fill = NSColor.gray, ink = NSColor.black
            appearance.performAsCurrentDrawingAppearance {
                fill = NSColor.tertiarySystemFill.usingColorSpace(.sRGB) ?? .gray
                ink = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black
            }
            disc = AnyView(HostAvatar.disc(mark, size: diameter, fill: AnyShapeStyle(Color(nsColor: fill)),
                                           ink: Color(nsColor: ink)))
        case .offHighlighted:
            // On the menu's blue highlight: white, as a template image turns.
            disc = AnyView(HostAvatar.disc(mark, size: diameter, fill: AnyShapeStyle(Color.white.opacity(0.22)),
                                           ink: .white))
        }
        let renderer = ImageRenderer(content: disc.frame(width: diameter, height: diameter))
        renderer.scale = scale
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: diameter, height: diameter))
        image.accessibilityDescription = HostAvatar.name(of: mark)
        cache[key] = image
        return image
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
