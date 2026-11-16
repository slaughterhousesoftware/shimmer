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
            SettingsField("Video") {
                HStack(spacing: 8) {
                    CompactPopup(selection: $settings.height, [("1920 × 1080", 1080), ("1280 × 720", 720)])
                    .accessibilityLabel("Resolution")
                    CompactPopup(selection: $settings.fps, [("60 Hz", 60), ("30 Hz", 30)])
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
                    CompactPopup(selection: $settings.hevc, [("HEVC", true), ("H.264", false)])
                    Toggle("HDR", isOn: $settings.hdr)
                        .fixedSize()
                        .disabled(!settings.hevc)
                        .help(settings.hevc ? "Brighter highlights, deeper colour" : "HDR needs HEVC")
                }
            }

            SettingsField("Presentation") {
                CompactPopup(selection: $settings.presentation,
                             PlayStationSettings.Presentation.allCases.map { ($0.displayName, $0) })
                .help(settings.presentation == .lowestLatency
                    ? "Each frame shows the moment it is decoded."
                    : "Frames wait for the display: steadier, a little more lag.")
            }

            // Everything the pad does: haptics, then the triggers and light.
            SettingsField("Controller") {
                CompactPopup(selection: $settings.haptics,
                             PlayStationSettings.HapticsMode.allCases.map { ($0.displayName, $0) })
                .help("Haptic feedback needs a DualSense; Rumble suits other controllers.")
                Toggle("Adaptive triggers", isOn: $settings.adaptiveTriggers)
                Toggle("Light bar colours from the console", isOn: $settings.lightBar)
                    .settingsStackedToggle()
            }
        }
    }
}
