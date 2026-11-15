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
    private var awdl = AWDLGuard.shared

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

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsField("Codec") {
                if let host = model.selectedHost {
                    Picker("", selection: codecSelection) {
                        ForEach(HostCodecPreference.allCases) { pref in
                            Text(pref.displayName).tag(pref)
                        }
                    }
                    .labelsHidden()
                    .settingsControl()
                } else {
                    Text("Pair a PC to choose the codec it streams with.")
                        .foregroundStyle(.secondary)
                }
            }

            SettingsField("HDR") {
                Toggle("Brighter highlights, deeper colour", isOn: $model.customHDR)
            }

            SettingsField("Wi-Fi") {
                Toggle("Reduce lag spikes on Wi-Fi", isOn: Binding(
                    get: { awdl.enabled }, set: { awdl.setEnabled($0) }))
                    .disabled(awdl.installing)
                SettingsHelp("AirDrop, AirPlay and Sidecar share your Wi-Fi radio and can interrupt the "
                    + "stream. This pauses them while you play and turns them back on after. The first "
                    + "time, macOS asks for your password. Not needed on Ethernet.")
                if let error = awdl.lastError, !awdl.enabled {
                    Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { reloadCodec() }
        .onChange(of: model.selectedHost?.id) { _, _ in reloadCodec() }
    }

    private func reloadCodec() {
        codecPref = model.selectedHost.map { HostCodecPreference.load(for: $0.id) } ?? .auto
    }
}
