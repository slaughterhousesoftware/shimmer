//
//  PlayStationSettingsPane.swift
//
//  The PlayStation tab: a PS5 stream's own settings (PlayStationSettings),
//  in the same gutter rows as the Sunshine tab. They apply from the next
//  stream.
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
                .settingsControl()
                SettingsHelp("The PS5 streams at 1080p at most.")
            }

            SettingsField("Frame rate") {
                Picker("", selection: $settings.fps) {
                    Text("60 Hz").tag(60)
                    Text("30 Hz").tag(30)
                }
                .labelsHidden()
                .settingsControl()
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
                SettingsHelp(settings.bitrateAuto
                    ? "The console's own setting, lowered when the network drops packets."
                    : "Sent as is and held: a sharper picture, but no backing off on a weak connection.")
            }

            SettingsField("Codec") {
                Picker("", selection: $settings.hevc) {
                    Text("HEVC").tag(true)
                    Text("H.264").tag(false)
                }
                .labelsHidden()
                .settingsControl()
                SettingsHelp(settings.hevc ? "Sharper for the same bitrate."
                                           : "Only if HEVC's picture breaks up.")
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
                .settingsControl()
                SettingsHelp(settings.presentation == .lowestLatency
                    ? "Each frame appears the moment it is decoded."
                    : "Frames wait for the display's refresh, evening out network hiccups at a little latency.")
            }

            SettingsField("Haptics") {
                Picker("", selection: $settings.haptics) {
                    ForEach(PlayStationSettings.HapticsMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .settingsControl()
                SettingsHelp("Haptic feedback plays the console's haptics on a DualSense, over USB or "
                    + "Bluetooth. Rumble suits other controllers.")
            }

            SettingsField("Controller") {
                Toggle("Adaptive triggers", isOn: $settings.adaptiveTriggers)
                Toggle("Light bar colours from the console", isOn: $settings.lightBar)
                    .settingsStackedToggle()
            }

            SettingsField("When the stream ends") {
                Toggle("Put the PS5 in rest mode", isOn: $settings.restWhenStreamEnds)
            }
        }
    }
}
