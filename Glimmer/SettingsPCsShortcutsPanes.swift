//
//  SettingsPCsShortcutsPanes.swift
//
//  The Controller tab: the connected pads, listed as System Settings' Game
//  Controllers lists them (a click opens that pane), and the settings for
//  what a game may do to them - one set for every machine, PS5 and PC alike.
//

import AppKit
import GameController
import SwiftUI

// MARK: - Controller tab

/// The Controller tab: the connected pads on top, listed as System
/// Settings' Game Controllers lists them (a click opens that pane, for a
/// pad's own settings), then what games may do to them.
struct ControllerTabPage: View {
    /// System Settings' Game Controllers pane - its extension allows the
    /// x-apple.systempreferences scheme. There is no public link to one
    /// pad's page, so the pane opens on its list.
    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Game-Controller-Settings.extension")!

    var body: some View {
        @Bindable var settings = ControllerSettings.shared
        Form {
            Section {
                ControllerList()
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
    }
}

/// One connected pad as the list shows it.
struct ControllerEntry: Identifiable {
    let id: Int
    let name: String
    /// Steam's glyph name for the pad (AppModel.steamControllerKind).
    let kind: String
    let battery: (percent: Int, charging: Bool?)?

    var status: String {
        guard let battery else { return "Connected" }
        return battery.charging == true ? "Charging · \(battery.percent)%" : "Connected · \(battery.percent)% battery"
    }

    /// GameController reads no battery for a DualSense while the raw-HID
    /// reader has it open; that reader's one battery is this pad's only when
    /// it's the only DualSense.
    static func hidBatteryApplies(kind: String, dualSenseCount: Int) -> Bool {
        kind == "ps5" && dualSenseCount == 1
    }

    /// Every connected gamepad, in GameController's order.
    @MainActor static func connected() -> [ControllerEntry] {
        if AppModel.debugKnob("fake-controllers") != nil {
            return [ControllerEntry(id: 0, name: "DualSense Wireless Controller", kind: "ps5", battery: (85, false)),
                    ControllerEntry(id: 1, name: "Xbox Wireless Controller", kind: "xbox", battery: (40, true))]
        }
        let pads = GCController.controllers().filter { $0.extendedGamepad != nil }
        let dualSenses = pads.filter { $0.productCategory == GCProductCategoryDualSense }.count
        return pads.enumerated().map { index, pad in
            let kind = AppModel.steamControllerKind(productCategory: pad.productCategory, vendorName: pad.vendorName)
            var battery = pad.battery.flatMap(ControllerBattery.uiReading)
            if battery == nil, hidBatteryApplies(kind: kind, dualSenseCount: dualSenses),
               let hid = DualSenseHID.shared.battery {
                battery = (hid.percent, hid.charging)
            }
            let vendor = pad.vendorName ?? ""
            return ControllerEntry(id: index, name: vendor.isEmpty ? pad.productCategory : vendor,
                                   kind: kind, battery: battery)
        }
    }
}

/// The connected pads, one row each; none: one row saying so. Every row
/// opens System Settings' Game Controllers.
private struct ControllerList: View {
    @Environment(AppModel.self) private var model

    private var entries: [ControllerEntry] {
        // GameController's registry isn't observable: these make the list
        // follow pads arriving, leaving and draining.
        _ = model.controllerConnected
        _ = model.controllerBatteryTick
        return ControllerEntry.connected()
    }

    var body: some View {
        let entries = entries
        if entries.isEmpty {
            ControllerRow(kind: "generic", name: "No controller connected", status: nil)
        } else {
            ForEach(entries) { entry in
                ControllerRow(kind: entry.kind, name: entry.name, status: entry.status)
            }
        }
    }
}

/// A pad as System Settings lists it: its brand tile, its name over a green
/// dot and its state, a chevron. Laid out like a machine's Stream row.
private struct ControllerRow: View {
    let kind: String
    let name: String
    let status: String?

    var body: some View {
        Button {
            NSWorkspace.shared.open(ControllerTabPage.systemSettingsURL)
        } label: {
            HStack(spacing: RowIcon.gap) {
                ControllerTile(kind: kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).lineLimit(1)
                    if let status {
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
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Game Controllers in System Settings")
        .accessibilityLabel([name, status].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens Game Controllers in System Settings")
    }
}

/// A pad's brand tile, as System Settings draws it: a rounded square in the
/// brand's colour with its logo in white.
struct ControllerTile: View {
    let kind: String

    static func style(kind: String) -> (symbol: String, rgb: UInt32) {
        switch kind {
        case "ps5", "ps4": return ("playstation.logo", 0x0070D1)
        case "xbox": return ("xbox.logo", 0x107C10)
        case "switchpro", "gamecube": return ("gamecontroller.fill", 0xE60012)
        default: return ("gamecontroller.fill", 0x8E8E93)
        }
    }

    var body: some View {
        let style = Self.style(kind: kind)
        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
            .fill(Color(red: Double((style.rgb >> 16) & 255) / 255, green: Double((style.rgb >> 8) & 255) / 255,
                        blue: Double(style.rgb & 255) / 255))
            .frame(width: RowIcon.column, height: RowIcon.column)
            .overlay {
                RowIcon(symbol: style.symbol, side: 17, column: 21)
                    .foregroundStyle(.white)
            }
    }
}
