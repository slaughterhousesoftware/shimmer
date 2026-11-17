//
//  SettingsVideoPane.swift
//
//  The Video pane: the codec the selected PC is allowed to send (the same
//  per-host preference the launcher's context menu edits) and HDR.
//  Size / rate / bitrate belong to the Stream pane. The stats overlay moved to
//  General, next to Troubleshooting - it is a diagnostic, not a picture setting.
//

import SwiftUI

struct VideoPane: View {
    @Environment(AppModel.self) private var model

    /// Mirror of the selected host's persisted codec preference. Loaded on
    /// appear and whenever the selected host changes; writes go straight back
    /// through `HostCodecPreference.save` and bump the launcher's chip.
    @State private var codecPref: HostCodecPreference = .auto

    private var codecSelection: Binding<HostCodecPreference> {
        Binding(
            get: { codecPref },
            set: { pref in
                codecPref = pref
                guard let host = model.selectedHost else { return }
                HostCodecPreference.save(pref, for: host.id)
                model.displayInfoRevision &+= 1
            })
    }

    /// Rows of the page's Video section, after the stream size and bitrate.
    var body: some View {
        @Bindable var model = model
        Group {
            SettingsRow("Codec") {
                SettingsSegmentedControl(selection: codecSelection, options: HostCodecPreference.allCases.map {
                    .init(value: $0, title: $0 == .auto ? "Automatic" : $0.displayName)
                })
            }
            .help("Automatic uses AV1 when the PC and this Mac both can, else HEVC.")
            .disabled(model.selectedHost == nil)
            Toggle(isOn: $model.customHDR) {
                Text("HDR")
                Text("Brighter highlights, deeper colour.")
            }
        }
        .onAppear { reloadCodec() }
        .onChange(of: model.selectedHost?.id) { _, _ in reloadCodec() }
    }

    private func reloadCodec() {
        codecPref = model.selectedHost.map { HostCodecPreference.load(for: $0.id) } ?? .auto
    }
}
