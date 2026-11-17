//
//  SettingsStreamPane.swift
//
//  The Stream pane: what the next stream asks the host for - resolution, frame
//  rate, bitrate - and how it shows on this Mac (full screen / window, the
//  notch, Picture in Picture). Laid out with the Tailscale-style gutter rows in
//  SettingsChrome.swift.
//
//  The resolution and frame-rate pickers are VIEWS of `qualityPreset` + the
//  Custom numbers (see Models/StreamChoices.swift), so nothing new is persisted
//  for them and an existing install reads back exactly what it had. The write
//  half lives on AppModel (`apply(_:)`) and is round-tripped in
//  GlimmerTests/StreamChoicesTests.swift.
//

import SwiftUI

struct StreamPane: View {
    @Environment(AppModel.self) private var model

    /// "Custom…" was picked while the Custom number still equals a standard
    /// rate; without this the picker would snap back to that rate's row and
    /// the field would never appear. Cleared by any other pick.
    @State private var customFrameRateEntry = false

    // MARK: Picker bindings

    private var resolutionSelection: Binding<ResolutionChoice> {
        Binding(get: { model.resolutionChoice }, set: { model.apply($0) })
    }

    private var frameRateSelection: Binding<FrameRateChoice> {
        Binding(
            get: {
                if customFrameRateEntry { return .custom }
                return model.frameRateChoice
            },
            set: { choice in
                customFrameRateEntry = (choice == .custom)
                model.apply(choice)
            })
    }

    /// The slider rides the stepped scale; while automatic it rests on the
    /// recommendation (disabled), so turning automatic off starts there.
    private var bitrateSliderIndex: Binding<Double> {
        Binding(
            get: { Double(BitrateScale.nearestIndex(toMbps: model.effectiveBitrateKbps / 1000)) },
            set: { model.manualBitrateMbps = BitrateScale.stepsMbps[Int($0.rounded())] })
    }

    // MARK: Labels

    private func resolutionLabel(_ choice: ResolutionChoice) -> String {
        switch choice {
        case .standard(let size): return "\(size.width) × \(size.height)"
        // Not offered; a PC saved on one moves to a standard size on load.
        case .matchDisplay, .hidpi, .custom: return ""
        }
    }

    private func frameRateLabel(_ choice: FrameRateChoice) -> String {
        switch choice {
        case .fixed(let hz): return "\(hz) Hz"
        case .custom: return "Custom…"
        }
    }

    // MARK: Clamps (run on EVERY commit, focus loss included)

    private func clampCustomFPS() {
        let fps = StreamSizeBounds.clampFPS(model.customFPS)
        if fps != model.customFPS { model.customFPS = fps }
    }

    /// Rows of the page's Video section (a grouped Form, System Settings style).
    var body: some View {
        @Bindable var model = model
        Picker("Resolution", selection: resolutionSelection) {
            ForEach(ResolutionChoice.all, id: \.self) { Text(resolutionLabel($0)).tag($0) }
        }
        Picker("Frame rate", selection: frameRateSelection) {
            ForEach(FrameRateChoice.all, id: \.self) { Text(frameRateLabel($0)).tag($0) }
        }
        if frameRateSelection.wrappedValue == .custom {
            LabeledContent("Custom frame rate") {
                HStack(spacing: 4) {
                    TextField("", value: $model.customFPS, format: .number)
                        .labelsHidden()
                        .frame(width: 56).multilineTextAlignment(.trailing).monospacedDigit()
                        .onChange(of: model.customFPS) { _, _ in clampCustomFPS() }
                    Text("Hz").foregroundStyle(.secondary)
                }
            }
        }
        BitrateMenu(automatic: $model.bitrateAuto, mbps: $model.manualBitrateMbps,
                    automaticMbps: model.recommendedBitrateMbpsNow,
                    maxMbps: BitrateSlider.stopsMbps.last ?? 300)
    }
}

/// Bitrate as System Settings would offer it: one popup, Automatic (with what
/// it works out to) and then the slider's old snap points.
struct BitrateMenu: View {
    @Binding var automatic: Bool
    @Binding var mbps: Int
    let automaticMbps: Int
    let maxMbps: Int

    private var stops: [Int] { BitrateSlider.stopsMbps.filter { $0 <= maxMbps } }

    var body: some View {
        Picker("Bitrate", selection: Binding<Int>(
            get: { automatic ? 0 : (stops.min { abs($0 - mbps) < abs($1 - mbps) } ?? mbps) },
            set: { value in
                if value == 0 {
                    automatic = true
                } else {
                    // Off first: turning automatic off seeds its own value.
                    automatic = false
                    mbps = value
                }
            })) {
            Text("Automatic (\(automaticMbps) Mbps)").tag(0)
            Divider()
            ForEach(stops, id: \.self) { Text("\($0) Mbps").tag($0) }
        }
    }
}

/// How any stream - Sunshine or PlayStation - shows and behaves on this Mac:
/// General's Stream and Performance sections (Rex-style grouped Form rows -
/// the title, a grey line under it, the control on the right).
struct StreamWindowPane: View {
    @Environment(AppModel.self) private var model
    private var awdl = AWDLGuard.shared

    var body: some View {
        @Bindable var model = model
        Section {
            SettingsRow("Show the stream") {
                SettingsSegmentedControl(selection: $model.streamDisplayMode, options: StreamDisplayMode.allCases.map {
                    .init(value: $0, title: $0.displayName, symbol: $0.settingsSymbol)
                })
            }
            Toggle(isOn: $model.autoPictureInPicture) {
                Text("Picture in Picture when you switch away")
                Text("Moves the stream into a floating window when you switch apps.")
            }
            // A pad doesn't reset the Mac's idle timer, so a stream being
            // played would dim and sleep without this. Off means the Mac's
            // own rules apply even mid-stream.
            Toggle(isOn: Binding(
                get: { model.keepAwakePolicy.isOn },
                set: { model.keepAwakePolicy = KeepAwakePolicy(isOn: $0) })) {
                Text("Keep the Mac awake while streaming")
                Text("A controller doesn’t count as activity, so the Mac would otherwise sleep.")
            }
        } header: {
            FormSectionHeader("Stream")
        }

        Section {
            // One switch for Game Mode wherever the stream is. Holding it in a
            // window and Picture in Picture takes Xcode's gamepolicyctl
            // (GameModeBoost); without Xcode macOS still turns it on in full
            // screen by itself, and the switch can't change anything, so it
            // shows that instead. Checked on every draw - a file lookup.
            let hasXcode = GameModeBoost.tool() != nil
            Toggle(isOn: Binding(get: { hasXcode && model.gameModeDuringStreams },
                                 set: { model.gameModeDuringStreams = $0 })) {
                Text("Game Mode while streaming")
                Text(hasXcode
                     ? "Halves a Bluetooth controller’s input lag (7.5 ms instead of 15) in full screen, "
                        + "a window and Picture in Picture."
                     : "Without Xcode, macOS only turns Game Mode on in full screen.")
            }
            .disabled(!hasXcode)
            if !hasXcode {
                LabeledContent("Xcode adds it in a window and Picture in Picture") {
                    Link("Get Xcode", destination: URL(string: "macappstore://apps.apple.com/app/id497799835")!)
                }
            }
            Toggle(isOn: Binding(get: { awdl.enabled }, set: { awdl.setEnabled($0) })) {
                Text("Reduce lag spikes on Wi-Fi")
                Text("Pauses AirDrop, AirPlay and Sidecar while you play - they share the Wi-Fi radio. "
                    + "macOS asks for your password the first time. Not needed on Ethernet.")
            }
            .disabled(awdl.installing)
            if let error = awdl.lastError, !awdl.enabled {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
            // The cushion that rides out Wi-Fi hiccups can sit at 100+ ms for
            // minutes after one; this caps it at 60 ms on every link and takes
            // the occasional blip instead.
            Toggle(isOn: $model.preferLowAudioLatency) {
                Text("Prefer low audio latency")
                Text("Less audio buffering. Unstable connections may sound less smooth.")
            }
        } header: {
            FormSectionHeader("Performance")
        }
    }
}

extension StreamDisplayMode {
    /// The segment's glyph on General's "Show the stream" row.
    var settingsSymbol: String {
        switch self {
        case .fullScreen: return "arrow.up.left.and.arrow.down.right"
        case .window: return "macwindow"
        }
    }
}
