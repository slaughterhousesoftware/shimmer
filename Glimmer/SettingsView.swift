//
//  SettingsView.swift
//
//  The whole app in one window, shaped like Tailscale's: a centred row of icon
//  tabs at the top, and everything else below it.
//
//    Computers - the PCs sidebar and the selected PC's cover grid, with the
//                add/remove actions along the bottom (Tailscale's Accounts tab)
//    General   - grouped sections of rows, Rex / System Settings style
//    Controller - the connected pad, and what games may do to it
//    About     - the centred identity page
//
//  There is deliberately no `Settings` scene and no second window: a SwiftUI
//  Settings scene IS a separate window, which is the thing being removed here.
//  ⌘, and the App-menu item just select the Settings tab (see GlimmerApp).
//

import AppKit
import SwiftUI

struct AppShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var activeState
    @State private var pairingTarget: PCPairingTarget?
    /// Tabs built so far. A tab is built on its first visit and then only
    /// shown and hidden: rebuilding a page on every switch re-ran its layout
    /// (profiled), and threw away its scroll position and state.
    @State private var builtTabs: Set<SettingsTab> = []

    private var showsWelcome: Bool {
        model.hosts.isEmpty && model.settingsTab == .computers
    }

    /// Each tab's own height; General's grouped Form scrolls within it.
    private var contentHeight: CGFloat {
        showsWelcome ? 520 - 32 : model.settingsTab.windowHeight
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // The title bar area: the system title is hidden (see
                // WindowChromeTweak) so it can be centred, clear of the traffic
                // lights, exactly as the reference app has it. The title itself
                // is drawn in the overlay below; this keeps its room.
                VStack(spacing: 0) {
                    Color.clear.frame(height: 30)
                    if !showsWelcome {
                        SettingsTabBar(selection: $model.settingsTab)
                    }
                }
                .background {
                    if showsWelcome {
                        Color(nsColor: .windowBackgroundColor)
                    } else {
                        SettingsHeaderBackground()
                    }
                }
                if !showsWelcome { Divider() }
            }
            ZStack(alignment: .top) {
                ForEach(SettingsTab.allCases) { tab in
                    if tab == model.settingsTab || builtTabs.contains(tab) {
                        let shown = tab == model.settingsTab
                        page(for: tab)
                            .opacity(shown ? 1 : 0)
                            .allowsHitTesting(shown)
                            .accessibilityHidden(!shown)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // Back, below the title bar rather than in it: in the title row it
            // sat on the zoom button and the title bar took its clicks, which
            // left a PC or PS5 opened by mistake with no way back.
            .overlay(alignment: .topLeading) {
                if showsWelcome, pairingTarget != nil {
                    Button {
                        pairingTarget = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(.primary.opacity(0.06), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.pairingInFlight)
                    .help("Back")
                    .accessibilityLabel("Back to welcome")
                    .padding(.leading, 14)
                    .padding(.top, 8)
                }
            }
        }
        // The title, drawn ABOVE the pages rather than beside them. The
        // welcome page's content is a scroll view straight under the title, so
        // macOS stretches it up beneath the title bar and lays its scroll-edge
        // blur over the top 32pt; a title painted underneath came out smeared.
        .overlay(alignment: .top) {
            Text("Shimmer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(activeState == .inactive ? .secondary : .primary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .allowsHitTesting(false)
        }
        // Waived on the WHOLE stack, not just the title row. Waiving it on the
        // title alone drew that row beside the traffic lights but still let the
        // layout reserve the title bar's 32pt for everything below, so the tab
        // strip began ~40pt lower than the reference app's - all of it empty.
        .ignoresSafeArea(.container, edges: .top)
        // Fixed, not resizable - the window follows the tab.
        .frame(width: SettingsMetrics.windowWidth, height: contentHeight, alignment: .top)
        .background(Color(nsColor: showsWelcome ? .windowBackgroundColor : .textBackgroundColor))
        .onChange(of: model.settingsTab, initial: true) { _, tab in
            builtTabs.insert(tab)
            if tab != .computers { pairingTarget = nil }
        }
    }

    @ViewBuilder
    private func page(for tab: SettingsTab) -> some View {
        switch tab {
        case .computers: ComputersTab(pairingTarget: $pairingTarget)
        case .general: GeneralTabPage()
        case .controller: ControllerTabPage()
        case .about: AboutPane()
        }
    }
}

/// The controls and the app around the stream: shortcuts, the pad, login,
/// the Wi-Fi helper, troubleshooting, diagnostics. Laid out like Rex's (and
/// System Settings') panes: bold section titles over rounded groups, each row
/// a title with a grey line under it and its control on the right - the same
/// grouped Form a machine's page on Servers uses.
private struct GeneralTabPage: View {
    var body: some View {
        Form {
            StreamWindowPane()
            AppPane()
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}

