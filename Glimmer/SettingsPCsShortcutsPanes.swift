//
//  SettingsPCsShortcutsPanes.swift
//
//  The Controller tab: the pad that is connected (with a button test), and
//  the settings for what a game may do to it - one set for every machine,
//  PS5 and PC alike.
//

import AppKit
import GameController
import SwiftUI

// MARK: - Controller tab

/// The Controller tab: the connected pad on top, as a machine's page opens
/// with its Stream row, then what games may do to it.
struct ControllerTabPage: View {
    @State private var testing = false

    var body: some View {
        @Bindable var settings = ControllerSettings.shared
        Form {
            Section {
                ConnectedControllerRow(test: { testing = true })
            }
            Section {
                Picker("Vibration", selection: $settings.vibration) {
                    ForEach(ControllerSettings.Vibration.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Adaptive triggers", isOn: $settings.adaptiveTriggers)
                Toggle(isOn: $settings.lightBar) {
                    Text("Light bar colours from the game")
                    Text("Games set the controller’s light.")
                }
            } header: {
                FormSectionHeader("Feedback")
            }
            Section {
                RawHIDControl()
            } header: {
                FormSectionHeader("Buttons")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .sheet(isPresented: $testing) { ControllerTestSheet() }
    }
}

/// The connected pad: its art, its name, a green dot with its battery, and
/// Test Buttons. Laid out like a machine's Stream row (RowIcon, 13 pt
/// name over an 11 pt line).
private struct ConnectedControllerRow: View {
    @Environment(AppModel.self) private var model
    let test: () -> Void

    /// The first connected gamepad. Reading `controllerConnected` and the
    /// battery tick makes the row follow pads arriving, leaving and draining
    /// (GameController's registry isn't observable).
    private var pad: GCController? {
        _ = model.controllerConnected
        _ = model.controllerBatteryTick
        return GCController.controllers().first { $0.extendedGamepad != nil }
    }

    var body: some View {
        let pad = pad
        HStack(spacing: RowIcon.gap) {
            RowIcon(asset: MenuBarBatteryGlyph.glyphName(kind: model.menuBarControllerKind ?? "generic"))
                .foregroundStyle(pad == nil ? .secondary : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(pad.map(Self.name) ?? "No controller connected").lineLimit(1)
                if pad != nil {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Button("Test Buttons…", action: test)
                .buttonStyle(.bordered)
                .fixedSize()
                .disabled(pad == nil || model.isStreaming)
                .help("Shows the controller’s buttons, sticks and triggers live.")
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        guard let battery = model.menuBarControllerBattery else { return "Connected" }
        return battery.charging ? "Charging · \(battery.percent)%" : "Connected · \(battery.percent)% battery"
    }

    /// The pad's own name ("DualSense Wireless Controller"), else its kind.
    private static func name(_ pad: GCController) -> String {
        if let vendor = pad.vendorName, !vendor.isEmpty { return vendor }
        return pad.productCategory
    }
}

/// The live button test (the one Diagnostics shows), in a sheet.
private struct ControllerTestSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                ControllerInputTest(showsDiagnostics: false)
                    .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 540)
    }
}
