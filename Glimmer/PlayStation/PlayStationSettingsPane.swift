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

    /// The page's Video and Controller sections (a grouped Form).
    var body: some View {
        Section {
            Picker("Resolution", selection: $settings.height) {
                Text("1920 × 1080").tag(1080)
                Text("1280 × 720").tag(720)
            }
            Picker("Frame rate", selection: $settings.fps) {
                Text("60 Hz").tag(60)
                Text("30 Hz").tag(30)
            }
            BitrateMenu(automatic: $settings.bitrateAuto, mbps: $settings.bitrateMbps,
                        automaticMbps: PlayStationSettings.presetBitrateMbps,
                        maxMbps: PlayStationSettings.bitrateRangeMbps.upperBound)
            Picker("Codec", selection: $settings.hevc) {
                Text("HEVC").tag(true)
                Text("H.264").tag(false)
            }
            Toggle("HDR", isOn: $settings.hdr)
                .disabled(!settings.hevc)
                .help(settings.hevc ? "Brighter highlights, deeper colour" : "HDR needs HEVC")
            Picker("Presentation", selection: $settings.presentation) {
                ForEach(PlayStationSettings.Presentation.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .help(settings.presentation == .lowestLatency
                ? "Each frame shows the moment it is decoded."
                : "Frames wait for the display: steadier, a little more lag.")
        } header: {
            FormSectionHeader("Video")
        }
        Section {
            Picker("Vibration", selection: $settings.haptics) {
                ForEach(PlayStationSettings.HapticsMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .help("Haptic feedback needs a DualSense; Rumble suits other controllers.")
            Toggle("Adaptive triggers", isOn: $settings.adaptiveTriggers)
            Toggle("Light bar colours from the console", isOn: $settings.lightBar)
        } header: {
            FormSectionHeader("Controller")
        }
    }
}
