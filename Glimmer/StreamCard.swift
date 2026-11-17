//
//  StreamCard.swift
//
//  The first row of a machine's page, in the way System Settings heads its
//  Bluetooth and Apple Account panes: the machine's avatar, name and status,
//  with Picture in Picture and Stream where Bluetooth has its switch. While
//  this machine streams the row shows the stream - its state, Picture in
//  Picture (or back to the window), End Stream.
//

import SwiftUI

struct StreamHeader: View {
    @Environment(AppModel.self) private var model
    let host: Host
    /// What Stream launches: the chosen app on a PC, the console on a PS5.
    let app: LibraryApp?
    let address: String

    private var streamingHere: Bool { model.isStreaming && model.activeStreamHostID == host.id }
    private var connecting: Bool {
        if streamingHere, case .connecting = model.streamPhase { return true }
        return false
    }
    private var resumes: Bool { app.map { model.runningAppName == $0.name } ?? false }

    var body: some View {
        HStack(spacing: 10) {
            HostAvatar(host: host, size: 40,
                       status: model.hostStatusIndicator(for: host.id),
                       statusText: model.hostStatusLine(for: host.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(subtitleIsLive ? Color.green : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            buttons
        }
        .padding(.vertical, 3)
        .hostContextMenu(host)
    }

    private var subtitle: String {
        if streamingHere { return model.hostStatusLine(for: host.id) }
        if model.isStreaming { return "Another stream is running" }
        // The address has its own row under the card (Rex's Remote Address).
        return model.hostStatusLine(for: host.id)
    }

    private var subtitleIsLive: Bool { streamingHere && model.streamPhase == .streaming }

    /// Rex's header-card buttons: capsules on the right - Stream in the
    /// accent colour, Picture in Picture beside it, End Stream tinted red
    /// (Rex's "Stop Server…").
    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 6) {
            if connecting {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancelConnect() }
            } else if streamingHere {
                if model.nativeStreamPictureInPicture {
                    PictureInPictureButton(entering: false) { model.resumeStreamWindow() }
                        .help("Back to the stream window")
                } else {
                    PictureInPictureButton(entering: true) { model.enterPictureInPicture() }
                        .help("Continue in Picture in Picture")
                        .disabled(!model.activeStreamHasVideo)
                }
                Button("End Stream") { model.endStream() }
                    .tint(.red)
            } else {
                PictureInPictureButton(entering: true) {
                    guard let app else { return }
                    model.pictureInPictureLaunchRequestedAt = Date()
                    model.requestStream(app: app, on: host)
                }
                .help("Stream in Picture in Picture")
                Button {
                    guard let app else { return }
                    model.requestStream(app: app, on: host)
                } label: {
                    Label(resumes ? "Resume" : "Stream", systemImage: "play.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .fixedSize()
        .disabled(app == nil || (model.isStreaming && !streamingHere))
    }
}

/// Picture in Picture as its own button: the system's PiP glyph in the accent
/// colour beside Stream - one click streams straight into PiP.
private struct PictureInPictureButton: View {
    let entering: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: entering ? "pip.enter" : "pip.exit")
                .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
        }
        .accessibilityLabel(entering ? "Picture in Picture" : "Leave Picture in Picture")
    }
}
