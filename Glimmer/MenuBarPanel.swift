//
//  MenuBarPanel.swift
//
//  The menu bar menu on macOS 27, shown the way Control Center shows its
//  own: a fixed, clear window under the status item with the menu's glass
//  drawn inside it, through the status item's expanded-interface session
//  (NSStatusItemExpandedInterfaceDelegate) - so the menu bar still treats
//  it as the item's menu: the item highlights, the arrow keys move along
//  the menu bar, and another item's click closes it.
//
//  Why not NSMenu: an NSMenu resizes its window to follow a custom view,
//  and that resize is the whole cost of a disclosure's frame - 6.9 ms
//  median, 9.8 ms at p90 on Kevin's MacBook (Studio Display XDR, 120 Hz;
//  Shimmer's own work 0.03 ms), so the Servers list's settings opened at
//  60 fps with 8/17/25 ms frames mixed in. Control Center's Focus and Sound
//  menus never resize a window - theirs are 522 pt wide and nearly the
//  screen's height whatever they show. Here, on the same MacBook, the same
//  disclosure runs 92 frames one refresh (8.3 ms) apart with none late, at
//  0.3 ms a frame (MenuDisclosureList logs each one; measured 2026-11-18).
//
//  The rows are the menu's own (MenuBarController still builds an NSMenu
//  and shows its items' views here), laid out as NSMenu lays them: one
//  column, the menu's width, 6 pt of glass above the first and below the
//  last.
//

import AppKit

@available(macOS 27.0, *)
final class MenuBarPanel: NSPanel {
    /// Room around the glass for its shadow.
    static let margin: CGFloat = 40

    private let root = MenuPanelRootView()

    /// Esc or a click outside; with what it was, for the log.
    var onCancel: ((String) -> Void)?
    /// A key the rows don't take: the controller's ⌘-shortcuts.
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    /// The row view under the pointer (or the keyboard), or nil.
    var onHover: ((NSView?) -> Void)? {
        get { root.onHover }
        set { root.onHover = newValue }
    }

    private var monitors: [Any] = []

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        contentView = root
        setAccessibilitySubrole(.unknown)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: Showing

    /// Shows `items` (top to bottom) under `button`, Control Center's way:
    /// the menu's right edge flush with the right end of the item's
    /// highlight, its top just under the menu bar, kept on the screen.
    func show(items: [NSView], minimumWidth: CGFloat, under button: NSStatusBarButton, takingKeyboard: Bool = true) {
        guard let buttonWindow = button.window, let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let width = root.setItems(items, minimumWidth: minimumWidth)
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        var left = buttonFrame.maxX + Self.highlightOverhang - width
        left = min(left, screen.frame.maxX - Self.screenEdgeGap - width)
        left = max(left, screen.frame.minX + Self.screenEdgeGap)
        let top = Self.menuBarBottom(on: screen, buttonWindow: buttonWindow) - Self.topGap
        let frame = NSRect(x: left - Self.margin, y: visible.minY, width: width + Self.margin * 2,
                           height: top - visible.minY)
        setFrame(frame, display: false)
        Diag.debug("menu bar panel: button \(NSStringFromRect(buttonFrame)) in window \(NSStringFromRect(buttonWindow.frame)), screen \(NSStringFromRect(screen.frame)) visible \(NSStringFromRect(visible)), menu bar \(NSApp.mainMenu?.menuBarHeight ?? -1)", "MenuBar")
        root.menuInset = NSEdgeInsets(top: 0, left: Self.margin, bottom: 0, right: Self.margin)
        root.layoutItems()
        alphaValue = 1
        orderFrontRegardless()
        if takingKeyboard { makeKey() }
        startMonitoring()
    }

    /// The same panel shows a rebuilt menu (a server picked, the menu still up).
    func reload(items: [NSView], minimumWidth: CGFloat) {
        let width = root.setItems(items, minimumWidth: minimumWidth)
        if abs(width + Self.margin * 2 - frame.width) > 0.5 {
            var f = frame
            f.size.width = width + Self.margin * 2
            setFrame(f, display: false)
        }
        root.layoutItems()
    }

    func dismiss(animated: Bool) {
        stopMonitoring()
        guard isVisible else { return }
        guard animated else { orderOut(nil); root.clear(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.orderOut(nil)
                self.root.clear()
            }
        })
    }

    // Control Center's place, measured at native 2x on Kevin's MacBook
    // (2026-11-18): its pop-ups (Battery, Sound) hang from the right end of
    // their item's highlight - the glass's right edge and the highlight's
    // on the same pixel. Shimmer's highlight ends 2 pt past its button's
    // frame (1 pt past the item's accessibility frame, which is a point
    // wider than the button): placed at +1 pt the glass ended a point
    // short. Their tops sit 1 pt under the menu bar. (NSMenu instead hangs
    // its left edge 8 pt left of the item.)
    private static let highlightOverhang: CGFloat = 2
    private static let topGap: CGFloat = 1
    private static let screenEdgeGap: CGFloat = 6

    /// The menu bar's bottom edge on `screen`. Not the status item's
    /// window's: on Kevin's Studio Display XDR that reaches 2 pt below the
    /// bar (the menu opened 3 pt under it; the Sound menu's opens 1 pt
    /// under). The bar's height comes from the notch's safe area, the
    /// screen's visible frame, or the main menu - whichever this Space
    /// reports - and must agree with the window to within a few points.
    private static func menuBarBottom(on screen: NSScreen, buttonWindow: NSWindow) -> CGFloat {
        let fromWindow = buttonWindow.frame.minY
        let heights = [screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY,
                       NSApp.mainMenu?.menuBarHeight ?? 0]
        guard let height = heights.first(where: { $0 > 0 }) else { return fromWindow }
        let bottom = screen.frame.maxY - height
        return abs(bottom - fromWindow) <= 6 ? bottom : fromWindow
    }

    // MARK: Closing on clicks elsewhere

    private func startMonitoring() {
        stopMonitoring()
        // Another app: the menu bar's own session sees clicks on other menu
        // bar items; a click anywhere else closes the menu too, as a menu's.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                          handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.onCancel?("a click in another app") }
        }) { monitors.append(global) }
        // Shimmer's own windows, or the clear part of this one.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                        handler: { [weak self] event in
            let inPanel = event.window === self
            let point = event.locationInWindow
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                guard !inPanel || !self.root.menuContains(point) else { return false }
                self.onCancel?(inPanel ? "a click beside the menu" : "a click in another Shimmer window")
                // A click in the clear part of the panel goes nowhere.
                return inPanel
            }
            return swallow ? nil : event
        }) { monitors.append(local) }
    }

    private func stopMonitoring() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?("Esc")                              // Esc
        case 125: root.moveKeyboardHighlight(by: 1)            // ↓
        case 126: root.moveKeyboardHighlight(by: -1)           // ↑
        case 36, 76, 49: root.pressKeyboardHighlight()          // Return, Enter, Space
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onCancel?("Esc") }
}

/// The panel's content: the glass, at the menu's size, and the rows in it.
@available(macOS 27.0, *)
final class MenuPanelRootView: NSView {
    override var isFlipped: Bool { true }

    var menuInset = NSEdgeInsets()
    var onHover: ((NSView?) -> Void)?

    private let glass = NSGlassEffectView()
    private let column = MenuPanelColumn()
    private var items: [NSView] = []
    private var observers: [NSObjectProtocol] = []
    private var isLaying = false

    /// The glass above the first row and below the last: the Sound menu's
    /// 6 pt under its last row (NSMenu's own is 5).
    static let verticalPadding: CGFloat = 6
    static let cornerRadius: CGFloat = 13

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.cornerRadius = Self.cornerRadius
        glass.contentView = column
        addSubview(glass)
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
        setAccessibilityLabel("Shimmer")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Takes the rows; returns the menu's width (its widest row, at least
    /// `minimumWidth`, as NSMenu sizes itself).
    @discardableResult
    func setItems(_ views: [NSView], minimumWidth: CGFloat) -> CGFloat {
        clear()
        items = views
        let width = max(minimumWidth, views.map(\.frame.width).max() ?? 0).rounded(.up)
        for view in views {
            view.removeFromSuperview()
            view.autoresizingMask = []
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
            column.addSubview(view)
            // A row that changes height (the Servers list opening its
            // settings, every display frame) re-lays the menu at once, as
            // NSMenu follows a custom view's frame.
            view.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutItems() }
            })
        }
        menuWidth = width
        return width
    }

    private(set) var menuWidth: CGFloat = 0

    func clear() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        items.forEach { $0.removeFromSuperview() }
        items = []
        keyboardIndex = nil
    }

    /// Stacks the rows and sizes the glass around them, from the top.
    func layoutItems() {
        guard !isLaying else { return }
        isLaying = true
        defer { isLaying = false }
        var y = Self.verticalPadding
        for view in items {
            let f = NSRect(x: 0, y: y, width: menuWidth, height: view.frame.height)
            if view.frame != f { view.frame = f }
            y += view.frame.height
        }
        let height = y + Self.verticalPadding
        let glassFrame = NSRect(x: menuInset.left, y: 0, width: menuWidth, height: height)
        if glass.frame != glassFrame { glass.frame = glassFrame }
        if column.frame != glass.bounds { column.frame = glass.bounds }
    }

    func menuContains(_ windowPoint: NSPoint) -> Bool {
        glass.frame.contains(convert(windowPoint, from: nil))
    }

    // Clicks in the clear part go through to the local monitor (closing).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard glass.frame.contains(local) else { return nil }
        return super.hitTest(point)
    }

    // MARK: Pointer

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { keyboardIndex = nil; onHover?(nil) }

    private func hover(at point: NSPoint) {
        keyboardIndex = nil
        guard glass.frame.contains(point) else { onHover?(nil); return }
        let inColumn = column.convert(point, from: self)
        onHover?(items.first { $0.frame.contains(inColumn) })
    }

    // MARK: Keyboard

    /// The rows the arrow keys step through, in order down the menu.
    private var keyRows: [MenuRowView] {
        func rows(in view: NSView) -> [MenuRowView] {
            if let row = view as? MenuRowView { return row.isHiddenOrHasHiddenAncestor ? [] : [row] }
            return view.subviews.flatMap(rows)
        }
        return items.flatMap(rows).filter { $0.alphaValue > 0 && $0.window != nil }
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }

    private var keyboardIndex: Int?

    func moveKeyboardHighlight(by step: Int) {
        let rows = keyRows
        guard !rows.isEmpty else { return }
        let current = keyboardIndex ?? rows.firstIndex { $0.isHovered } ?? (step > 0 ? -1 : rows.count)
        let next = min(max(current + step, 0), rows.count - 1)
        keyboardIndex = next
        for (i, row) in rows.enumerated() { row.isHovered = i == next }
    }

    func pressKeyboardHighlight() {
        guard let row = keyRows.first(where: \.isHovered) else { return }
        _ = row.accessibilityPerformPress()
    }
}

/// The rows' column inside the glass, top-down and clipped to its corners.
@available(macOS 27.0, *)
final class MenuPanelColumn: NSView {
    override var isFlipped: Bool { true }
}
