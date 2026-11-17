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
            Picker("Resolution", selection: $settings.height) {
                Text("1080p").tag(1080)
                Text("720p").tag(720)
            }
            .pickerStyle(.segmented)
            Picker("Frame rate", selection: $settings.fps) {
                Text("60 Hz").tag(60)
                Text("30 Hz").tag(30)
            }
            .pickerStyle(.segmented)
            BitrateMenu(automatic: $settings.bitrateAuto, mbps: $settings.bitrateMbps,
                        automaticMbps: PlayStationSettings.presetBitrateMbps,
                        maxMbps: PlayStationSettings.bitrateRangeMbps.upperBound)
            Picker("Codec", selection: $settings.hevc) {
                Text("HEVC").tag(true)
                Text("H.264").tag(false)
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $settings.hdr) {
                Text("HDR")
                Text(settings.hevc ? "Brighter highlights, deeper colour." : "HDR needs HEVC.")
            }
            .disabled(!settings.hevc)
            Picker(selection: $settings.presentation) {
                Label("Lowest latency", systemImage: "bolt").tag(PlayStationSettings.Presentation.lowestLatency)
                Label("Smooth", systemImage: "water.waves").tag(PlayStationSettings.Presentation.smooth)
            } label: {
                Text("Presentation")
            }
            .pickerStyle(.segmented)
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
