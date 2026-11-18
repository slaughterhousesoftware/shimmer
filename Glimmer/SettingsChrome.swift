//
//  SettingsChrome.swift
//
//  The settings vocabulary, modelled on Tailscale for macOS: a centred row of
//  icon tabs at the top of the SAME window, then flat two-column rows - the
//  label right-aligned in a fixed gutter, its controls left-aligned beside it,
//  explanatory copy underneath in grey. No sidebar, no grouped cards, no
//  separate Settings window.
//
//  Why this shape rather than SwiftUI's `Form(.grouped)`: grouped Form puts
//  every Section in its own rounded card, so a pane made of one- and two-row
//  sections reads as a stack of disconnected plates. Tailscale's gutter does
//  the grouping instead - the label names a group and its rows sit together
//  without any box - which is why a dense pane still scans.
//

import AppKit
import SwiftUI

/// Opaque chrome: behind-window vibrancy picks up wallpaper and can make this
/// header much brighter than the reference. Keep the light header white and
/// use the system's slightly lighter charcoal surface in dark appearance.
struct SettingsHeaderBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color(nsColor: colorScheme == .dark ? .underPageBackgroundColor : .windowBackgroundColor)
    }
}

// MARK: - Tabs

/// The pages the settings view can show. Raw values are persisted as the
/// remembered tab, so leave them alone when renaming a title.
enum SettingsTab: String, CaseIterable, Identifiable {
    case computers, general, controller, about

    var id: String { rawValue }

    /// A remembered tab. The Sunshine ("stream") and PlayStation tabs became
    /// each machine's page on Servers.
    init?(persisted raw: String) {
        switch raw {
        case "stream", "playStation": self = .computers
        default: self.init(rawValue: raw)
        }
    }

    var title: String {
        switch self {
        // The enum case stays `computers` (the --debug-open-settings rawValue
        // and existing references); only the shown name changed to "Servers".
        case .computers: return "Servers"
        case .general: return "General"
        case .controller: return "Controller"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        // A rack, matching the "Servers" name (Sunshine hosts) - and distinct
        // from the "display"/"desktopcomputer" glyph the host rows and menu bar
        // already use for a machine.
        case .computers: return "server.rack"
        case .general: return "slider.horizontal.3"
        case .controller: return "gamecontroller"
        case .about: return "info.circle"
        }
    }

    /// The window's height on every tab (content only: macOS adds a 32pt
    /// title bar even with `.fullSizeContentView`): Tailscale's Accounts
    /// window. One height, so switching tabs never resizes the window - a
    /// resize re-laid out the whole page on every frame of its animation,
    /// and with the pages kept (AppShell) a switch is close to free
    /// (profiled on the MacBook: 39-88 ms a switch before, 15-36 after).
    /// A page that runs longer scrolls.
    var windowHeight: CGFloat { 528 - 32 }
}

/// The centred icon-over-label tab strip. Tailscale draws the selected tab as
/// a rounded neutral plate with an accent-coloured glyph and label, and the
/// rest monochrome - no underline, no segmented control.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    /// macOS desaturates window chrome when the window is not frontmost, and
    /// the reference app's tabs do exactly that. Without this the selected tab
    /// stayed vivid blue on an inactive window, which is what made the two
    /// headers look so different side by side.
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 0)
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 20, weight: .regular))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(tint(for: tab))
                    // Keep content-sized tabs, using the reference's 20pt
                    // symbols and 12pt labels rather than scaling the window.
                    .padding(.vertical, 5)
                    .padding(.horizontal, 7)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selection == tab ? plateFill : .clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(selection == tab
                                                  ? Color.primary.opacity(0.13) : .clear,
                                                  lineWidth: 1))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
        .padding(.horizontal, 12)
    }

    private var isActive: Bool { activeState != .inactive }

    private func tint(for tab: SettingsTab) -> Color {
        guard selection == tab else { return .secondary }
        return isActive ? Color.accentColor : .secondary
    }

    private var plateFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(isActive ? 0.13 : 0.08)
            : (isActive ? Color.white.opacity(0.94) : Color.primary.opacity(0.055))
    }
}

// MARK: - Rows

/// The gutter every label is right-aligned into. One constant so each pane
/// lines up with the others as the user flips tabs - a per-pane width makes
/// the labels visibly jump.
enum SettingsMetrics {
    /// At the reference screenshot's 2× scale, a 72px avatar sits in a
    /// 96px account row. Keep server rows on that same 36 / 48pt rhythm.
    static let sidebarIconSize: CGFloat = 36
    static let sidebarRowHeight: CGFloat = 48
    /// The reference window's exact width, and its per-tab heights. It is not
    /// resizable - the zoom and minimise buttons are disabled - and the height
    /// changes with the tab rather than the user dragging it.
    static let windowWidth: CGFloat = 600

    /// Servers: the machine list beside a machine's page.
    static let serversSidebarWidth: CGFloat = 190
}

/// A permission status row: plain status dot, message, and trailing native action.
struct SettingsNotice<Action: View>: View {
    let message: String
    var tint: Color = .red
    @ViewBuilder var action: () -> Action

    /// A grouped-Form row: status dot and message on the left, the action on
    /// the right, where a switch would be.
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tint)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            action()
                .layoutPriority(1)
        }
    }
}

/// The bitrate slider both kinds of PC share: a dozen snap points with a
/// tick on each, up to `maxMbps`. (Bazzite's had 26 ticks; across a 260pt
/// control they land on fractional pixels and look unevenly spaced.)
struct BitrateSlider: View {
    nonisolated static let stopsMbps = [5, 10, 15, 20, 30, 40, 50, 75, 100, 150, 200, 300]
    let mbps: Int
    let maxMbps: Int
    let set: (Int) -> Void

    /// The snap point nearest `mbps` among those up to `maxMbps`.
    nonisolated static func nearestStopIndex(mbps: Int, maxMbps: Int) -> Int {
        let stops = stopsMbps.filter { $0 <= maxMbps }
        return stops.enumerated().min(by: { abs($0.element - mbps) < abs($1.element - mbps) })?.offset ?? 0
    }

    var body: some View {
        let stops = Self.stopsMbps.filter { $0 <= maxMbps }
        Slider(value: Binding(
            get: { Double(Self.nearestStopIndex(mbps: mbps, maxMbps: maxMbps)) },
            set: { set(stops[min(stops.count - 1, max(0, Int($0.rounded())))]) }),
               in: 0...Double(max(stops.count - 1, 1)), step: 1)
    }
}

/// A grouped Form's section heading, pulled up: macOS leaves ~38 pt between
/// one box and the next heading, System Settings about 20.
struct FormSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).padding(.top, -14)
    }
}

/// Rex's segmented control, built the way Rex builds it (read from Rex's
/// binary, RexMacOS.SettingsSegmentedControl): a real NSSegmentedControl, not a
/// SwiftUI imitation. What gives it the Liquid Glass pill instead of AppKit's
/// accent-blue fill is `role = .tabs` (macOS 27) on a capsule border; the rest
/// is Rex's sizing: the large control size (28 pt), the regular 13 pt system
/// font, SF Symbols at the font's point size, and each segment as wide as its
/// icon, title and 8 pt of padding a side.
struct SettingsSegmentedControl<Value: Hashable>: NSViewRepresentable {
    struct Option {
        let value: Value
        let title: String
        var symbol: String? = nil
    }

    @Binding var selection: Value
    let options: [Option]

    static var segmentHorizontalPadding: CGFloat { 8 }
    /// The gap AppKit leaves between a segment's image and its label.
    static var imageSpacing: CGFloat { 6 }

    final class Coordinator: NSObject {
        var parent: SettingsSegmentedControl
        var configured: [String] = []
        init(_ parent: SettingsSegmentedControl) { self.parent = parent }

        @objc func selectSegment(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index].value
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(frame: .zero)
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectSegment(_:))
        control.segmentStyle = .automatic
        control.controlSize = .large
        control.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        control.borderShape = .capsule
        if #available(macOS 27, *) { control.role = .tabs }
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        let signature = options.map { "\($0.title)|\($0.symbol ?? "")" }
        if context.coordinator.configured != signature {
            context.coordinator.configured = signature
            configureSegments(of: control)
        }
        control.selectedSegment = options.firstIndex { $0.value == selection } ?? -1
        let enabled = context.environment.isEnabled
        control.isEnabled = enabled
        control.alphaValue = enabled ? 1 : 0.5
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    private func configureSegments(of control: NSSegmentedControl) {
        let font = control.font ?? .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        control.segmentDistribution = .fit
        control.segmentCount = options.count
        for (index, option) in options.enumerated() {
            let image = option.symbol
                .flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
                .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular))
            image?.isTemplate = true
            control.setImage(image, forSegment: index)
            control.setLabel(option.title, forSegment: index)
            let titleWidth = (option.title as NSString).size(withAttributes: [.font: font]).width
            let imageWidth = image.map { $0.size.width + Self.imageSpacing } ?? 0
            control.setWidth((titleWidth + imageWidth + 2 * Self.segmentHorizontalPadding).rounded(.up), forSegment: index)
        }
    }
}

/// The Quality row: resolution and frame rate as two menus side by side,
/// `1920 × 1080 ⌃⌄  60 Hz ⌃⌄`. Each menu keeps the width of its widest value,
/// so changing one never slides the other along the row. (Tried and dropped
/// 2026-11-17: one capsule split into two menus, and one combined menu.)
struct ResolutionFrameRateRow<Resolution: Hashable, FrameRate: Hashable>: View {
    @Binding var resolution: Resolution
    let resolutions: [(title: String, value: Resolution)]
    @Binding var frameRate: FrameRate
    let frameRates: [(title: String, value: FrameRate)]

    var body: some View {
        LabeledContent("Quality") {
            HStack(spacing: 6) {
                Self.menu("Resolution", $resolution, resolutions)
                Self.menu("Frame rate", $frameRate, frameRates)
            }
        }
    }

    private static func menu<V: Hashable>(_ title: String, _ selection: Binding<V>,
                                          _ options: [(title: String, value: V)]) -> some View {
        ZStack(alignment: .trailing) {
            // One invisible copy per value: the stack takes the widest.
            ForEach(options.indices, id: \.self) { index in
                picker(title, .constant(options[index].value), options)
                    .hidden()
                    .accessibilityHidden(true)
            }
            picker(title, selection, options)
        }
    }

    private static func picker<V: Hashable>(_ title: String, _ selection: Binding<V>,
                                            _ options: [(title: String, value: V)]) -> some View {
        Picker(title, selection: selection) {
            ForEach(options.indices, id: \.self) { Text(options[$0].title).tag(options[$0].value) }
        }
        .pickerStyle(.menu)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .labelsHidden()
        .fixedSize()
    }
}

/// A grouped-Form row whose title is centred against a taller control (the
/// segmented control): LabeledContent aligns by text baseline, which left the
/// title riding high beside the 28pt control.
struct SettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
            Spacer(minLength: 12)
            control
        }
    }
}
