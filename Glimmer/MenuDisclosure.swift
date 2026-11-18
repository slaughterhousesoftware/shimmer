//
//  MenuDisclosure.swift
//
//  The Servers list in the menu bar menu, with the server in use opening
//  its stream settings in place under it - Apple's Sound menu opening the
//  AirPods (Listening Mode and the rest), copied down to the motion.
//
//  There is no API for this. NSMenu has no inline disclosure, and
//  ControlCenter.app's binary suggests its menus aren't NSMenus at all but
//  SwiftUI in custom panels (it names SoundMenuExtraView, ModuleWindow, an
//  NSPanel subclass, and FlatDisclosureGroupStyle). macOS 27's public
//  NSStatusItemExpandedInterfaceDelegate would let Shimmer show a panel of
//  its own instead; staying an NSMenu keeps the system's menu behaviour.
//  NSMenu does follow a custom item view's frame while it is open, though
//  ("Changes to the view's frame during tracking are reflected immediately
//  in the menu", NSMenuItem.h), so the whole list is one item's view, sized
//  on every display frame by the springs below.
//
//  The motion, measured frame by frame off a 60 fps recording of the Sound
//  menu on macOS 27 (Kevin's MacBook, 2026-11-18; three opens and three
//  closes, each fitted within ~1%):
//  - the rows below slide and the opened band fades on one spring:
//    SwiftUI's snappy at 0.35 s (damping 0.85 - it settles a hair past its
//    mark, ~1.5 pt, and back). The chevron turns on it too - assumed: the
//    pointer covered the chevron in the recording;
//  - the menu's height chases them on a slower critically damped spring:
//    smooth at 0.42 s. So opening, the rows run ahead and the bottom of the
//    menu (Settings…, Quit) uncovers them; closing, the rows slide up over
//    the fading band, and the bottom follows, leaving a gap that closes.
//  - the band itself doesn't move: it is in place from the first frame and
//    fades, drawn under the rows that pass over it.
//  SwiftUI's own Spring does the arithmetic (`update(value:velocity:...)`).
//  Recorded back off Shimmer the same way, its curves match Apple's: the
//  height within 0.7-1.5% rms over all six cycles, the rows sliding within
//  0.5-0.8%, the fade within ~2% (design/menu-bar/disclosure-motion).
//
//  The rows are subviews of one menu item, so arrow keys reach the list as
//  a whole, not each server (VoiceOver still reaches each row's button).
//

import AppKit
import SwiftUI

enum MenuDisclosureMotion {
    /// The rows below, the band's fade and the chevron.
    static let content = Spring.snappy(duration: 0.35)
    /// The menu's height, chasing the content.
    static let height = Spring.smooth(duration: 0.42)
}

/// The Servers rows as one menu item's view, so they can move independently
/// of the menu's own stacking - rows slide over a fading band, which separate
/// menu items can't do. Hover is the list's own: the menu highlights the one
/// item, and the list puts the band on the row under the pointer, including
/// when rows slide under a still pointer.
final class MenuDisclosureList: NSView {
    private let rows: [MenuRowView]
    private let anchor: Int?
    private let well: NSView?
    private(set) var isExpanded: Bool

    /// Spring state: `content` moves the rows, fades the band and turns the
    /// chevron; `height` opens the menu. 0 closed, 1 open, either may
    /// overshoot a little on the way.
    private struct Motion { var content = 0.0, contentVelocity = 0.0, height = 0.0, heightVelocity = 0.0 }
    private var motion = Motion()
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?

    override var isFlipped: Bool { true }

    /// `well`: the view opened under row `under`, if any. `continuing`: the
    /// list this one replaces in a rebuild of the open menu - its motion
    /// carries on instead of jumping to the end.
    init(rows: [MenuRowView], well: (under: Int, view: NSView)?, expanded: Bool,
         continuing earlier: MenuDisclosureList? = nil) {
        self.rows = rows
        anchor = well?.under
        self.well = well?.view
        isExpanded = expanded && well != nil
        let width = max(rows.map(\.frame.width).max() ?? 0, well?.view.frame.width ?? 0)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        autoresizingMask = [.width]
        if let earlier, earlier.anchor == anchor {
            // Wherever the old one was - it animates on from there.
            motion = earlier.motion
        } else {
            let end = isExpanded ? 1.0 : 0
            motion = Motion(content: end, height: end)
        }
        // Drawn in order: the band first, so the rows below pass over it.
        if let w = self.well { addSubview(w) }
        rows.forEach(addSubview)
        if let anchor, let row = rows[anchor] as? MenuServerRow { row.setAccessibilityExpanded(isExpanded) }
        // Last in the list, the band ends on the menu's own separator below:
        // its bottom hairline would double it.
        (self.well as? MenuDisclosureWell)?.showsBottomEdge = (anchor ?? rows.count) < rows.count - 1
        layoutForMotion()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var isAnimating: Bool {
        let target = isExpanded ? 1.0 : 0
        return abs(motion.content - target) > 0.0005 || abs(motion.contentVelocity) > 0.005
            || abs(motion.height - target) > 0.0005 || abs(motion.heightVelocity) > 0.005
    }

    /// Opens or closes the band under the server in use, animated.
    func setExpanded(_ expanded: Bool) {
        guard well != nil, expanded != isExpanded else { return }
        isExpanded = expanded
        if let anchor, let row = rows[anchor] as? MenuServerRow { row.setAccessibilityExpanded(expanded) }
        startAnimating()
    }

    /// One step of the springs (the display link's, or a test's).
    func advance(by dt: TimeInterval) {
        let target = isExpanded ? 1.0 : 0
        var m = motion
        var content = m.content, speed = m.contentVelocity
        MenuDisclosureMotion.content.update(value: &content, velocity: &speed, target: target, deltaTime: dt)
        m.content = content
        m.contentVelocity = speed
        var height = m.height, velocity = m.heightVelocity
        MenuDisclosureMotion.height.update(value: &height, velocity: &velocity, target: m.content, deltaTime: dt)
        m.height = height
        m.heightVelocity = velocity
        motion = m
        if !isAnimating { motion = Motion(content: target, height: target) }
        layoutForMotion()
    }

    /// The menu closed: no more frames to draw.
    func stopAnimating() {
        link?.invalidate()
        link = nil
        lastTick = nil
    }

    private func startAnimating() {
        guard isAnimating, link == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        // The menu's run loop mode while it's open is event tracking.
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        // The first frame after a click moves by one frame's worth.
        let dt = lastTick.map { min(max(now - $0, 0), 1.0 / 30) } ?? (link.targetTimestamp - now)
        lastTick = now
        advance(by: max(dt, 0))
        updateHoverFromPointer()
        if !isAnimating { stopAnimating() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimating() } else { startAnimating() }
    }

    // MARK: Layout

    private var baseHeight: CGFloat { rows.reduce(0) { $0 + $1.frame.height } }
    private var wellHeight: CGFloat { well?.frame.height ?? 0 }

    private func pixelAligned(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (value * scale).rounded() / scale
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutForMotion() }

    private func layoutForMotion() {
        let content = CGFloat(motion.content)
        var y: CGFloat = 0
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: row.frame.height)
            y += row.frame.height
            if i == anchor, let well {
                // The band holds still under its row and fades; the rows
                // after it slide by the band's height times the spring.
                well.frame = NSRect(x: 0, y: y, width: bounds.width, height: well.frame.height)
                well.alphaValue = min(max(content, 0), 1)
                well.isHidden = !isExpanded && content <= 0.0005
                y += pixelAligned(well.frame.height * content)
            }
        }
        if let anchor, let row = rows[anchor] as? MenuServerRow { row.disclosureProgress = content }
        let height = pixelAligned(baseHeight + wellHeight * CGFloat(max(motion.height, 0)))
        if frame.height != height { setFrameSize(NSSize(width: frame.width, height: height)) }
    }

    // MARK: Pointer

    /// Closing, the band takes no clicks: what's under the pointer is the
    /// rows sliding over it, or nothing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let well, !isExpanded, let hit, hit.isDescendant(of: well) { return nil }
        return hit
    }

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { clearHover() }

    /// Rows slide under a pointer that isn't moving: follow them.
    private func updateHoverFromPointer() {
        guard let window else { return }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func updateHover(at point: NSPoint) {
        // The last row drawn is on top: the one sliding over the band.
        let hovered = bounds.contains(point) ? rows.last { $0.frame.contains(point) } : nil
        for row in rows { row.isHovered = row === hovered }
    }

    func clearHover() { rows.forEach { $0.isHovered = false } }
}

/// The band a server opens under it: the Sound menu's AirPods band, measured
/// at 2x off Kevin's recording (2026-11-18) - full width, ~4.5% darker than
/// the menu, a 1 pt line at its top and bottom, and between its groups a
/// line 4.5 pt in from each side (the dark-mode fill isn't measured: a guess
/// at the same recess). Each group is a header in Control Center's type
/// (MenuSectionHeaderRow: 12 pt semibold, secondary grey) over its control.
/// The spacing is the band's: the first header's baseline 25.25 pt below the
/// top, a later one's 20.5 pt below its divider; 7.25 pt from a baseline to
/// its rows; a divider 5.25 pt under a group's last row; the band's bottom
/// 5 pt under its last.
final class MenuDisclosureWell: NSView {
    struct Group {
        var title: String?
        var view: NSView
    }

    private var dividers: [CGFloat] = []

    /// The line under the band, where rows follow it.
    var showsBottomEdge = true { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    init(groups: [Group]) {
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 0))
        autoresizingMask = [.width]
        let baseline = MenuSectionHeaderRow.baseline
        var y: CGFloat = 0
        for (i, group) in groups.enumerated() {
            if let title = group.title {
                let headerTop: CGFloat
                if i == 0 {
                    headerTop = 25.25 - baseline
                } else {
                    y += 5.25
                    dividers.append(y)
                    headerTop = y + 20.5 - baseline
                }
                // The header's row runs on to where its control starts.
                let header = MenuSectionHeaderRow(title, height: baseline + 7.25)
                header.frame = NSRect(x: 0, y: headerTop, width: frame.width, height: baseline + 7.25)
                header.autoresizingMask = [.width]
                addSubview(header)
                y = header.frame.maxY
            }
            group.view.frame = NSRect(x: 0, y: y, width: frame.width, height: group.view.frame.height)
            group.view.autoresizingMask = [.width]
            addSubview(group.view)
            y += group.view.frame.height
        }
        setFrameSize(NSSize(width: frame.width, height: y + 5))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Darkens what the menu's glass shows, as the system's band does.
    override var allowsVibrancy: Bool { true }

    private static let fill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.black.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.045)
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.fill.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        if showsBottomEdge { NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill() }
        for y in dividers {
            NSRect(x: 4.5, y: y - 0.5, width: bounds.width - 9, height: 1).fill()
        }
    }
}
