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
//  NSPanel subclass, and FlatDisclosureGroupStyle). So the whole list is
//  one view, sized on every display frame by the springs below, and
//  whatever shows the menu follows its height: on macOS 27 the menu's own
//  panel (MenuBarPanel), where a frame costs 0.3 ms and the motion holds
//  120 Hz; before that an NSMenu, which does follow a custom item view's
//  frame while it is open ("Changes to the view's frame during tracking
//  are reflected immediately in the menu", NSMenuItem.h) but pays a window
//  resize for it every frame.
//
//  The motion, measured frame by frame off native-pixel recordings of the
//  Sound menu's AirPods row on macOS 27 (Kevin's MacBook, 2026-11-18; the
//  menu's bottom edge over three opens and three closes, the row below the
//  band over the closes; the springs fitted jointly, 1.2% rms):
//  - the rows below slide and the opened band fades on one spring:
//    SwiftUI's snappy at 0.32 s (stiffness 385.5, damping 0.85 of critical -
//    it settles a hair past its mark, ~2 pt, and back). The chevron turns
//    on it too - assumed: the chevron shows only under the pointer;
//  - the menu's height chases them on a slightly overdamped spring
//    (stiffness 300, damping 38: 1.1 times critical), so its last few
//    points creep in as the Sound menu's do, never past. From 5% of the
//    way, it reaches 25/50/80/95/99% at 62/122/219/343/483 ms; Apple's
//    at 55/114/206/339/492. (A critically damped 0.40 s fitted as well
//    overall but landed its last 1% 45 ms early. A first fit off a 60 fps
//    screen recording gave 0.35 and 0.42 - visibly slower side by side.)
//    So opening, the rows run ahead and the bottom of the
//    menu (Settings…, Quit) uncovers them; closing, the rows slide up over
//    the fading band, and the bottom follows, leaving a gap that closes.
//  - the band itself doesn't move: it is in place from the first frame and
//    fades, drawn under the rows that pass over it.
//  MenuSpring steps the springs, in steps of 1/1200 s at most, rather
//  than SwiftUI's Spring: that clamps damping at critical (asked for 38,
//  it used 34.6, and the height landed 80 ms early), and its update over a
//  whole 120 Hz frame drifts from the true curve. Shimmer recorded back
//  matched each model to within a few ms. The fit's scripts are in
//  design/menu-bar/disclosure-motion.
//
//  The rows are subviews of one menu item, so arrow keys reach the list as
//  a whole, not each server (VoiceOver still reaches each row's button).
//

import AppKit

enum MenuDisclosureMotion {
    /// The rows below, the band's fade and the chevron: SwiftUI's
    /// `.snappy(duration: 0.32)`.
    static let content = MenuSpring(duration: 0.32, dampingRatio: 0.85)
    /// The menu's height, chasing the content.
    static let height = MenuSpring(stiffness: 300, damping: 38)
    /// The longest step the springs take at once; a display frame is cut
    /// into steps this short, so the motion is the same at any refresh rate.
    static let maximumStep: TimeInterval = 1.0 / 1200
}

/// A damped spring of unit mass, stepped semi-implicitly (velocity, then
/// position) - the model the motion was fitted with. Any damping, over
/// critical too.
struct MenuSpring {
    let stiffness: Double
    let damping: Double

    init(stiffness: Double, damping: Double) {
        self.stiffness = stiffness
        self.damping = damping
    }

    /// SwiftUI's parametrisation: `duration` the period undamped.
    init(duration: Double, dampingRatio: Double) {
        stiffness = pow(2 * .pi / duration, 2)
        damping = 4 * .pi * dampingRatio / duration
    }

    func step(value: inout Double, velocity: inout Double, target: Double, by dt: Double) {
        velocity += (stiffness * (target - value) - damping * velocity) * dt
        value += velocity * dt
    }
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
    /// The animation in flight, for the log: the display link's gaps and
    /// what each frame cost here (the layout it sets off included), in ms.
    private var pacing: (gaps: [Double], work: [Double]) = ([], [])

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
        // The band is its full height from the first frame; the list's own
        // height uncovers it.
        clipsToBounds = true
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
        var content = motion.content, speed = motion.contentVelocity
        var height = motion.height, velocity = motion.heightVelocity
        let steps = max(1, Int((dt / MenuDisclosureMotion.maximumStep).rounded(.up)))
        let step = dt / Double(steps)
        for _ in 0..<steps {
            MenuDisclosureMotion.content.step(value: &content, velocity: &speed, target: target, by: step)
            MenuDisclosureMotion.height.step(value: &height, velocity: &velocity, target: content, by: step)
        }
        motion = Motion(content: content, contentVelocity: speed, height: height, heightVelocity: velocity)
        if !isAnimating { motion = Motion(content: target, height: target) }
        layoutForMotion()
    }

    /// The menu closed: no more frames to draw.
    func stopAnimating() {
        link?.invalidate()
        link = nil
        lastTick = nil
        logPacing()
    }

    /// One line per animation: whether every frame came one refresh after
    /// the last. (In an NSMenu on a 120 Hz screen they don't - the menu's
    /// window resize costs most of a frame; see MenuBarPanel.)
    private func logPacing() {
        let (gaps, work) = pacing
        pacing = ([], [])
        guard gaps.count > 8 else { return }
        let refresh = 1000 / Double(max(window?.screen?.maximumFramesPerSecond ?? 60, 1))
        let sortedGaps = gaps.sorted(), sortedWork = work.sorted()
        let late = gaps.filter { $0 > refresh * 1.5 }.count
        let summary = String(format: "%d frames at %.0f Hz, %d late; gap median %.1f ms, worst %.1f; "
                             + "work median %.2f ms, worst %.2f", gaps.count, 1000 / refresh, late,
                             sortedGaps[sortedGaps.count / 2], sortedGaps.last ?? 0,
                             sortedWork[sortedWork.count / 2], sortedWork.last ?? 0)
        Diag.info("disclosure: \(summary)", "MenuBar")
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
        if let lastTick { pacing.gaps.append((now - lastTick) * 1000) }
        lastTick = now
        let began = CACurrentMediaTime()
        advance(by: max(dt, 0))
        updateHoverFromPointer()
        pacing.work.append((CACurrentMediaTime() - began) * 1000)
        if !isAnimating { stopAnimating() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimating() } else { startAnimating() }
    }

    // MARK: Layout

    private var baseHeight: CGFloat { rows.reduce(0) { $0 + $1.frame.height } }
    /// What opening adds to the list: the band and the plain glass above
    /// and below it.
    private var openExtent: CGFloat { well.map { $0.frame.height + MenuDisclosureWell.gap * 2 } ?? 0 }

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
                // after it slide by its extent times the spring.
                well.frame = NSRect(x: 0, y: y + MenuDisclosureWell.gap, width: bounds.width,
                                    height: well.frame.height)
                well.alphaValue = min(max(content, 0), 1)
                well.isHidden = !isExpanded && content <= 0.0005
                y += pixelAligned(openExtent * content)
            }
        }
        if let anchor, let row = rows[anchor] as? MenuServerRow { row.disclosureProgress = content }
        let height = pixelAligned(baseHeight + openExtent * CGFloat(max(motion.height, 0)))
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

/// The band a server opens under it: the Sound menu's AirPods band,
/// measured at native 2x on Kevin's MacBook (2026-11-18, dark; the menu bar
/// pop-up and Control Center's Sound panel lay it out alike). The menu's
/// full width, with 5 pt of plain glass between it and the rows above and
/// below (MenuDisclosureList leaves those). Its tint is MenuTintView's: in
/// the dark it adds light (+21 of 255) rather than darkening, with no line
/// at its top or bottom; between its groups a 1 pt line 5 pt in from each
/// side. Each group is a header in Control Center's type
/// (MenuSectionHeaderRow: 12 pt semibold, secondary grey) over its control.
/// The spacing is the band's, all on the half-point grid: the first
/// header's baseline 26.5 pt below the top; 7 pt from a baseline to its
/// rows; a divider's top 4.5 pt under a group's last row, and the next
/// header's baseline 21.5 pt under that; the band's bottom 5.5 pt under its
/// last row. (The light fill, ~4.5% darker, is off Kevin's earlier 60 fps
/// recording, not a native capture.)
final class MenuDisclosureWell: NSView {
    struct Group {
        var title: String?
        var view: NSView
    }

    /// Plain glass above and below the band.
    static let gap: CGFloat = 5

    override var isFlipped: Bool { true }

    init(groups: [Group]) {
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 0))
        wantsLayer = true
        autoresizingMask = [.width]
        let fill = MenuTintView(frame: bounds)
        fill.tint = .band
        fill.autoresizingMask = [.width, .height]
        addSubview(fill)
        let baseline = MenuSectionHeaderRow.baseline
        var y: CGFloat = 0
        for (i, group) in groups.enumerated() {
            if let title = group.title {
                let titleBaseline: CGFloat
                if i == 0 {
                    titleBaseline = 26.5
                } else {
                    y += 4.5
                    let divider = MenuTintView(frame: NSRect(x: 5, y: y, width: frame.width - 10, height: 1))
                    divider.tint = .bandDivider
                    divider.autoresizingMask = [.width]
                    addSubview(divider)
                    titleBaseline = y + 21.5
                }
                // The header's row runs on to where its control starts.
                let header = MenuSectionHeaderRow(title, height: baseline + 7)
                header.frame = NSRect(x: 0, y: titleBaseline - baseline, width: frame.width, height: baseline + 7)
                header.autoresizingMask = [.width]
                addSubview(header)
                y = header.frame.maxY
            }
            group.view.frame = NSRect(x: 0, y: y, width: frame.width, height: group.view.frame.height)
            group.view.autoresizingMask = [.width]
            addSubview(group.view)
            y += group.view.frame.height
        }
        setFrameSize(NSSize(width: frame.width, height: y + 5.5))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The band fades with its parts each faded on its own, not flattened
    /// first. Its tints add light to the glass (MenuTintView's `plusL`); a
    /// group fade draws them into a clear layer first, where adding light
    /// is plain painting, and lays that over the glass - about 6 grey
    /// levels darker than the same tint added straight to the glass. So
    /// the band brightened by a step in the frame its opacity reached 1,
    /// as the motion settled (measured off Shimmer's recording, 2026-11-18).
    /// Faded part by part, adding light stays adding light at every
    /// opacity, and a fade to 1 lands exactly on the resting look.
    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        layer.allowsGroupOpacity = false
        return layer
    }
}
