//
//  PlayStationSettingsPane.swift
//
//  A PS5's page on Servers: its own settings (PlayStationSettings), in the
//  same grouped Form as a PC's page. They apply from the next stream. Rest
//  mode is on the page's Stream row.
//

import SwiftUI

struct PlayStationSettingsPane: View {
    @Bindable var settings: PlayStationSettings

    /// The page's Video and Controller sections (a grouped Form). Two-way
    /// choices are segmented, as Rex lays out its few-option rows.
    var body: some View {
        Section {
            SettingsRow("Resolution") {
                SettingsSegmentedControl(selection: $settings.height, options: [
                    .init(value: 1080, title: "1080p"), .init(value: 720, title: "720p"),
                ])
            }
            SettingsRow("Frame rate") {
                SettingsSegmentedControl(selection: $settings.fps, options: [
                    .init(value: 60, title: "60 Hz"), .init(value: 30, title: "30 Hz"),
                ])
            }
            BitrateMenu(automatic: $settings.bitrateAuto, mbps: $settings.bitrateMbps,
                        automaticMbps: PlayStationSettings.presetBitrateMbps,
                        maxMbps: PlayStationSettings.bitrateRangeMbps.upperBound)
            SettingsRow("Codec") {
                SettingsSegmentedControl(selection: $settings.hevc, options: [
                    .init(value: true, title: "HEVC"), .init(value: false, title: "H.264"),
                ])
            }
            Toggle(isOn: $settings.hdr) {
                Text("HDR")
                Text(settings.hevc ? "Brighter highlights, deeper colour." : "HDR needs HEVC.")
            }
            .disabled(!settings.hevc)
            SettingsRow("Presentation") {
                SettingsSegmentedControl(selection: $settings.presentation, options: [
                    .init(value: .lowestLatency, title: "Lowest latency", symbol: "bolt"),
                    .init(value: .smooth, title: "Smooth", symbol: "film"),
                ])
            }
            .help(settings.presentation == .lowestLatency
                ? "Each frame shows the moment it is decoded."
                : "Frames wait for the display: steadier, a little more lag.")
        } header: {
            FormSectionHeader("Video")
        }
        Section {
            Picker(selection: $settings.haptics) {
                ForEach(PlayStationSettings.HapticsMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            } label: {
                Text("Vibration")
                Text("Haptic feedback needs a DualSense; Rumble suits other controllers.")
            }
            Toggle("Adaptive triggers", isOn: $settings.adaptiveTriggers)
            Toggle(isOn: $settings.lightBar) {
                Text("Light bar colours from the console")
                Text("Games and the PS5 set the controller’s light.")
            }
        } header: {
            FormSectionHeader("Controller")
        }
    }
}
