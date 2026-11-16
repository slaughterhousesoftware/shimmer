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
        VStack(alignment: .leading, spacing: SettingsMetrics.serversRowSpacing) {
            SettingsField("Resolution") {
                HStack(spacing: 8) {
                    Picker("", selection: $settings.height) {
                        Text("1920 × 1080").tag(1080)
                        Text("1280 × 720").tag(720)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Resolution")
                    Picker("", selection: $settings.fps) {
                        Text("60 Hz").tag(60)
                        Text("30 Hz").tag(30)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Frame rate")
                }
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

            // Codec and HDR share a row: HDR needs HEVC.
            SettingsField("Codec") {
                HStack(spacing: 12) {
                    Picker("", selection: $settings.hevc) {
                        Text("HEVC").tag(true)
                        Text("H.264").tag(false)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Toggle("HDR", isOn: $settings.hdr)
                        .fixedSize()
                        .disabled(!settings.hevc)
                        .help(settings.hevc ? "Brighter highlights, deeper colour" : "HDR needs HEVC")
                }
            }

            SettingsField("Presentation") {
                Picker("", selection: $settings.presentation) {
                    ForEach(PlayStationSettings.Presentation.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .settingsPopup()
                .help(settings.presentation == .lowestLatency
                    ? "Each frame shows the moment it is decoded."
                    : "Frames wait for the display: steadier, a little more lag.")
            }

            // Everything the pad does: haptics, then the triggers and light.
            SettingsField("Controller") {
                Picker("", selection: $settings.haptics) {
                    ForEach(PlayStationSettings.HapticsMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .settingsPopup()
                .help("Haptic feedback needs a DualSense; Rumble suits other controllers.")
                Toggle("Adaptive triggers", isOn: $settings.adaptiveTriggers)
                Toggle("Light bar colours from the console", isOn: $settings.lightBar)
                    .settingsStackedToggle()
            }
        }
    }
}
