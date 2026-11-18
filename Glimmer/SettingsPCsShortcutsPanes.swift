//
//  SettingsPCsShortcutsPanes.swift
//
//  The Controller tab: the connected pads, listed as System Settings' Game
//  Controllers lists them (each with a button to that pane), and the settings for
//  what a game may do to them - one set for every machine, PS5 and PC alike.
//

import AppKit
import GameController
import SwiftUI

// MARK: - Controller tab

/// The Controller tab: the connected pads on top, listed as System
/// Settings' Game Controllers lists them (each with a button to that pane,
/// for a pad's own settings), then what games may do to them.
struct ControllerTabPage: View {
    /// System Settings' Game Controllers pane - its extension allows the
    /// x-apple.systempreferences scheme. There is no public link to one
    /// pad's page, so the pane opens on its list.
    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Game-Controller-Settings.extension")!

    var body: some View {
        @Bindable var settings = ControllerSettings.shared
        Form {
            ControllerList()
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

    /// The status line as System Settings writes it: "Connected", then
    /// " – ", the battery glyph and "Battery 85%" when the pad reports one.
    var batteryText: String? { battery.map { "Battery \($0.percent)%" } }
    var batterySymbol: String? { battery.map { Self.batterySymbol(percent: $0.percent, charging: $0.charging) } }
    var accessibilityStatus: String { ["Connected", batteryText].compactMap { $0 }.joined(separator: ", ") }

    /// SF Symbols' battery in its five steps, or with a bolt while charging.
    static func batterySymbol(percent: Int, charging: Bool?) -> String {
        if charging == true { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
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

/// The connected pads, one row each, in a card of their own; with none
/// connected there is no card at all, and the tab starts at Feedback. Every
/// row has a button that opens System Settings' Game Controllers.
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
        if !entries.isEmpty {
            Section {
                ForEach(entries) { entry in
                    ControllerRow(entry: entry)
                }
            }
        }
    }
}

/// A pad as System Settings lists it: the whole pad, its name over
/// "Connected – [battery] Battery 85%", and a button to that pane. Laid out
/// like a machine's Stream row.
private struct ControllerRow: View {
    let entry: ControllerEntry

    var body: some View {
        HStack(spacing: RowIcon.gap) {
            RowIcon(asset: ControllerArt.assetName(kind: entry.kind), side: 30, column: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                HStack(spacing: 4) {
                    Text("Connected")
                    if let batteryText = entry.batteryText, let symbol = entry.batterySymbol {
                        Text("–")
                        Image(systemName: symbol)
                        Text(batteryText)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(entry.accessibilityStatus)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Controller Settings…") {
                NSWorkspace.shared.open(ControllerTabPage.systemSettingsURL)
            }
            .fixedSize()
            .help("Open Game Controllers in System Settings")
        }
        .padding(.vertical, 2)
    }
}

/// A pad's whole outline, as Steam's Big Picture draws it: Steam's own
/// glyphs (scripts/assets/steam-controller_<kind>.svg), one per kind, kept
/// as vectors so they stay sharp at any size.
enum ControllerArt {
    static func assetName(kind: String) -> String {
        "ControllerArt-\(MenuBarBatteryGlyph.kinds.contains(kind) ? kind : "generic")"
    }
}
