//
//  MenuBarRows.swift
//
//  The two rows of the menu bar's menu that copy the Sound menu (macOS 27):
//  its volume slider - a quiet speaker, the slider, a loud speaker, nothing
//  else - and its output list's round marks, here one per server (Kevin,
//  2026-11-18: "just copy this"). Stock AppKit only: an NSSlider in a menu
//  item's view, and plain menu items with a drawn image.
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

/// A server's round mark for its menu row, like the Sound menu's outputs: the
/// system's logo (PlayStation, Tux, Windows, Apple) on a grey disc, or white
/// on the accent colour for the one in use. Drawn when the menu draws, so it
/// follows light and dark.
@MainActor
enum MenuHostMark {
    static let diameter: CGFloat = 26
    /// The logo's box inside the disc, before each mark's own scale.
    static let markBox: CGFloat = 15

    static func kind(of host: Host) -> HostSystemKind {
        if host.isPlayStation { return .playStation }
        return HostSystemKind.cached(hostID: host.id)
            ?? HostSystemKind.resolve(isPlayStation: false, ttl: nil, serverName: host.name)
    }

    /// The mark and its scale - HostSystemLogo's, so the four read one size.
    static func mark(for kind: HostSystemKind) -> (image: NSImage?, scale: CGFloat) {
        let symbol = NSImage.SymbolConfiguration(pointSize: markBox, weight: .regular)
        switch kind {
        case .playStation:
            return (NSImage(systemSymbolName: "playstation.logo", accessibilityDescription: nil)?
                .withSymbolConfiguration(symbol), 0.92)
        case .mac:
            return (NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil)?
                .withSymbolConfiguration(symbol), 0.78)
        case .windows: return (NSImage(named: "HostLogo-windows"), 0.74)
        case .linux: return (NSImage(named: "HostLogo-linux"), 0.9)
        }
    }

    static func image(for host: Host, current: Bool) -> NSImage {
        let kind = kind(of: host)
        let (mark, scale) = mark(for: kind)
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            (current ? NSColor.controlAccentColor : NSColor.tertiarySystemFill).setFill()
            NSBezierPath(ovalIn: rect).fill()
            guard let mark, mark.size.width > 0, mark.size.height > 0 else { return true }
            let box = markBox * scale
            let fit = min(box / mark.size.width, box / mark.size.height)
            let size = NSSize(width: mark.size.width * fit, height: mark.size.height * fit)
            let target = NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
                                width: size.width, height: size.height)
            let ink = current ? NSColor.white : NSColor.labelColor.withAlphaComponent(0.72)
            let tinted = NSImage(size: size, flipped: false) { inner in
                mark.draw(in: inner)
                ink.set()
                inner.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: target)
            return true
        }
        image.accessibilityDescription = HostSystemLogo.name(of: kind)
        return image
    }
}
