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
    case computers, general, about

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
        case .about: return "info.circle"
        }
    }

    /// Each tab's window height (content only: macOS adds a 32pt title bar
    /// even with `.fullSizeContentView`). Servers and General scroll inside it.
    var windowHeight: CGFloat {
        switch self {
        // Tailscale's Accounts window. A machine's page scrolls if its
        // settings run longer; the sidebar's bottom bar stays put.
        case .computers: return 528 - 32
        case .general: return 744 - 32
        case .about: return 540 - 32
        }
    }
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

/// Rex's segmented control, not AppKit's: a grey capsule track with the chosen
/// option lifted onto a white pill (icon and title), where NSSegmentedControl
/// fills the selected segment with the accent colour.
struct CapsuleSegmentedPicker<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var symbol: String? = nil
    }

    @Binding var selection: Value
    let options: [Option]
    @Namespace private var pill
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                segment(options[index])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07)))
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
    }

    private func segment(_ option: Option) -> some View {
        let chosen = option.value == selection
        return Button {
            guard !chosen else { return }
            withAnimation(.snappy(duration: 0.22)) { selection = option.value }
        } label: {
            HStack(spacing: 5) {
                if let symbol = option.symbol {
                    Image(systemName: symbol).imageScale(.medium)
                }
                Text(option.title)
            }
            .font(.system(size: 13))
            .foregroundStyle(chosen ? .primary : .secondary)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background {
                if chosen {
                    Capsule()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.18) : Color.white)
                        .shadow(color: .black.opacity(0.14), radius: 1.5, y: 0.5)
                        .overlay(Capsule().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A grouped-Form row whose title is centred against a taller control (the
/// capsule picker): LabeledContent aligns by text baseline, which left the
/// title riding high beside the 28pt capsule.
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
