//
//  PlayStationSettingsPane.swift
//
//  A PS5's page on Servers: its own settings (PlayStationSettings), in the
//  same gutter rows as a PC's page. They apply from the next stream. Rest
//  mode is on the page's Stream row.
//

import SwiftUI

struct PlayStationSettingsPane: View {
    @Bindable var settings: PlayStationSettings

    private var bitrate: Binding<Double> {
        // While automatic the thumb rests on the console's preset, matching
        // the label; turning automatic off starts from the last chosen value.
        Binding(get: { Double(settings.bitrateAuto ? PlayStationSettings.presetBitrateMbps : settings.bitrateMbps) },
                set: { settings.bitrateMbps = Int($0.rounded()) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsField("Resolution") {
                Picker("", selection: $settings.height) {
                    Text("1920 × 1080 (1080p)").tag(1080)
                    Text("1280 × 720 (720p)").tag(720)
                }
                .labelsHidden()
                .settingsPopup()
            }

            SettingsField("Frame rate") {
                Picker("", selection: $settings.fps) {
                    Text("60 Hz").tag(60)
                    Text("30 Hz").tag(30)
                }
                .labelsHidden()
                .settingsPopup()
            }

            SettingsField("Bitrate") {
                Toggle("Set automatically", isOn: $settings.bitrateAuto)
                HStack(spacing: 10) {
                    BitrateSlider(mbps: settings.bitrateAuto ? PlayStationSettings.presetBitrateMbps : settings.bitrateMbps,
                                  maxMbps: PlayStationSettings.bitrateRangeMbps.upperBound) { settings.bitrateMbps = $0 }
                        .settingsControl()
                        .disabled(settings.bitrateAuto)
                    Text(settings.bitrateAuto ? "\(PlayStationSettings.presetBitrateMbps) Mbps"
                                              : "\(settings.bitrateMbps) Mbps")
                        .monospacedDigit()
                        .foregroundStyle(settings.bitrateAuto ? .secondary : .primary)
                }
            }

            SettingsField("Codec") {
                Picker("", selection: $settings.hevc) {
                    Text("HEVC").tag(true)
                    Text("H.264").tag(false)
                }
                .labelsHidden()
                .settingsPopup()
            }

            SettingsField("HDR") {
                Toggle("Brighter highlights, deeper colour", isOn: $settings.hdr)
                    .disabled(!settings.hevc)
                if !settings.hevc { SettingsHelp("Needs HEVC.") }
            }

            SettingsField("Presentation") {
                Picker("", selection: $settings.presentation) {
                    ForEach(PlayStationSettings.Presentation.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .settingsPopup()
                SettingsHelp(settings.presentation == .lowestLatency
                    ? "Each frame shows the moment it is decoded."
                    : "Frames wait for the display: steadier, a little more lag.", checkbox: false)
            }

            SettingsField("Haptics") {
                Picker("", selection: $settings.haptics) {
                    ForEach(PlayStationSettings.HapticsMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .settingsPopup()
                SettingsHelp("Haptic feedback needs a DualSense; Rumble suits other controllers.", checkbox: false)
            }

            SettingsField("Controller") {
                Toggle("Adaptive triggers", isOn: $settings.adaptiveTriggers)
                Toggle("Light bar colours from the console", isOn: $settings.lightBar)
                    .settingsStackedToggle()
            }
        }
    }
}
