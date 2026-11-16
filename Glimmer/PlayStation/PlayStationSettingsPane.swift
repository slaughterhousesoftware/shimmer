//
//  PlayStationSettingsPane.swift
//
//  The PlayStation tab: a PS5 stream's own settings (PlayStationSettings),
//  in the same gutter rows as the Sunshine tab. They apply from the next
//  stream.
//

import SwiftUI

struct PlayStationSettingsPane: View {
    @Bindable private var settings = PlayStationSettings.shared

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
                .pickerStyle(.segmented)
                .settingsControl()
            }

            SettingsField("Bitrate") {
                Toggle("Set automatically", isOn: $settings.bitrateAuto)
                HStack(spacing: 10) {
                    Slider(value: bitrate,
                           in: Double(PlayStationSettings.bitrateRangeMbps.lowerBound)...Double(
                               PlayStationSettings.bitrateRangeMbps.upperBound),
                           step: 1)
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

            SettingsField("Video") {
                Toggle("HEVC", isOn: $settings.hevc)
                SettingsHelp("Sharper for the same bitrate. Turn off only if the picture breaks up.")
                Toggle("HDR", isOn: $settings.hdr)
                    .disabled(!settings.hevc)
                    .settingsStackedToggle()
                SettingsHelp("Only on a display that can show HDR, and with HEVC.")
            }

            SettingsField("Upscaling") {
                Picker("", selection: $settings.upscaling) {
                    ForEach(PlayStationSettings.Upscaling.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .settingsControl()
                SettingsHelp("Sharpens the 1080p stream to your screen's size with MetalFX. Adds about "
                    + "5 ms. Not used with HDR, or when the stream already fills its window.")
            }

            SettingsField("Presentation") {
                Picker("", selection: $settings.presentation) {
                    ForEach(PlayStationSettings.Presentation.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
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
                .pickerStyle(.segmented)
                .settingsControl()
                SettingsHelp("Haptic feedback plays the console's haptics on a DualSense, over USB or "
                    + "Bluetooth. Rumble suits other controllers.")
            }

            SettingsField("Controller") {
                Toggle("Adaptive triggers", isOn: $settings.adaptiveTriggers)
                Toggle("Light bar colours from the console", isOn: $settings.lightBar)
                    .settingsStackedToggle()
                Toggle("Game Mode for Bluetooth controllers", isOn: $settings.gameModeBoost)
                    .settingsStackedToggle()
                SettingsHelp("Turns on macOS Game Mode during the stream, in any window or Picture in "
                    + "Picture, so a Bluetooth DualSense answers twice as fast. Needs Xcode installed.")
            }

            SettingsField("When the stream ends") {
                Toggle("Put the PS5 in rest mode", isOn: $settings.restWhenStreamEnds)
            }
        }
    }
}
