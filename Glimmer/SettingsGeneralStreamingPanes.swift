//
//  SettingsGeneralStreamingPanes.swift
//
//  The App settings pane: login items, the stats overlay, and diagnostics.
//  (Wi-Fi smoothing moved to the Stream tab's Video pane - it tunes the stream.)
//  SettingsRoot composes panes across files, so the types are internal. (Filename keeps
//  its pre-redesign name - renaming means touching the pbxproj for zero
//  behavioural gain; the Stream / Video / Audio panes that replaced the old
//  Quality pane live in their own files.) `LoginItemManager`, the registration
//  plumbing behind the launch toggles, lives in
//  SettingsGeneralStreamingPanes+LoginItem.swift.
//

import AppKit
import os
import ServiceManagement
import SwiftUI

// MARK: - App

struct AppPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false

    /// True when macOS has the login item but it is pending the user's approval
    /// in System Settings > Login Items - surfaced inline so the user is not
    /// left with a toggle that silently does nothing at the next reboot.
    @State private var loginItemNeedsApproval = false

    /// Defer the SMAppService register/unregister off the SwiftUI `.onChange`
    /// transaction - running it inline (synchronous, XPC-backed) mid-update
    /// dismissed the window.
    private func scheduleLoginItemRegistration(launchAtLogin: Bool) {
        DispatchQueue.main.async {
            let status = LoginItemManager.apply(launchAtLogin: launchAtLogin)
            loginItemNeedsApproval = (status == .requiresApproval)
        }
    }

    /// General's App, Stream health and Coding agents sections.
    var body: some View {
        @Bindable var model = model
        Group {
            Section {
                // The login helper suppresses the window; Dock access remains
                // available whenever there is no useful menu-bar status.
                // Waiting for approval it isn't on, so no switch: a red dot
                // stands in its place until the user allows Shimmer.
                if loginItemNeedsApproval {
                    SettingsNotice(message: "Be ready at login: allow Shimmer in Login Items") {
                        Button("Open Settings…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .help("Turn on Shimmer under Allow in the Background. Starts quietly when you sign in.")
                } else {
                    Toggle(isOn: $launchAtLogin) {
                        Text("Be ready at login")
                        Text("Opens quietly when you log in.")
                    }
                    .onChange(of: launchAtLogin) { _, on in
                        scheduleLoginItemRegistration(launchAtLogin: on)
                    }
                }
            } header: {
                FormSectionHeader("App")
            }

            // Recording a stream and the stats overlay have no switch here:
            // an agent turns them on when a stream needs diagnosing
            // (`shimmerctl set recording on`; AgentControl.hiddenSettings).

            // The agent finds the bundled shimmerctl itself (the instructions
            // carry its path), so there's nothing to install or type here.
            Section {
                LabeledContent {
                    CLICopyButton("Copy Instructions") {
                        ShimmerCLIAgentInstructions.text(hostName: model.selectedHost?.displayName,
                            address: model.selectedHostRouteAddress)
                    }
                } label: {
                    Text("Coding agents")
                    Text("Lets AI coding tools diagnose problems.")
                }
            } header: {
                FormSectionHeader("Help")
            }

            if model.showDiagnostics {
                Section {
                    DisclosureGroup("Controller input test") {
                        ControllerInputTest()
                    }
                    DisclosureGroup("Logs") {
                        LogViewer()
                    }
                } header: {
                    FormSectionHeader("Diagnostics")
                }
            }
        }
        .onAppear { refreshLoginApproval() }
        // Approval happens in System Settings; re-check on the way back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginApproval()
        }
    }

    private func refreshLoginApproval() {
        guard launchAtLogin else { loginItemNeedsApproval = false; return }
        let service = SMAppService.loginItem(identifier: LoginItemManager.helperBundleID)
        loginItemNeedsApproval = (service.status == .requiresApproval)
    }
}
