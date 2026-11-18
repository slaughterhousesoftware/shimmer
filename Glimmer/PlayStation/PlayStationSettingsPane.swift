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

    /// The page's Video section (a grouped Form; the pad's settings are on
    /// the Controller tab). Two-way choices are segmented, as Rex lays out
    /// its few-option rows.
    var body: some View {
        Section {
            ResolutionFrameRateRow(
                resolution: $settings.height,
                resolutions: [("1920 × 1080", 1080), ("1280 × 720", 720)],
                frameRate: $settings.fps,
                frameRates: [("60 Hz", 60), ("30 Hz", 30)])
            BitrateMenu(automatic: $settings.bitrateAuto, mbps: $settings.bitrateMbps,
                        // Automatic sends the preset at 1080p only (AppModel+PlayStation).
                        automaticMbps: settings.height > 720 ? PlayStationSettings.presetBitrateMbps : nil,
                        maxMbps: PlayStationSettings.bitrateRangeMbps.upperBound)
            SettingsRow("Codec") {
                SettingsSegmentedControl(selection: $settings.hevc, options: [
                    .init(value: true, title: "HEVC"), .init(value: false, title: "H.264"),
                ])
            }
            Toggle("HDR", isOn: $settings.hdr)
                .disabled(!settings.hevc)
                .help(settings.hevc ? "" : "HDR needs HEVC")
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
    }
}
