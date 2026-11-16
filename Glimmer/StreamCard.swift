//
//  StreamCard.swift
//
//  The top of a machine's page: what to stream and the two ways to start it,
//  in one card set apart from the settings below. While this machine streams
//  the same card shows the stream - its state, Picture in Picture, End Stream.
//

import SwiftUI

struct StreamCard: View {
    @Environment(AppModel.self) private var model
    let host: Host
    let apps: [LibraryApp]
    @Binding var chosenAppName: String?

    private var chosen: LibraryApp? {
        apps.first { $0.name == (chosenAppName ?? model.heroTargetAppName) } ?? apps.first
    }
    private var streamingHere: Bool { model.isStreaming && model.activeStreamHostID == host.id }
    private var connecting: Bool {
        if streamingHere, case .connecting = model.streamPhase { return true }
        return false
    }
    private var resumes: Bool { chosen.map { model.runningAppName == $0.name } ?? false }

    var body: some View {
        HStack(spacing: 10) {
            tile
            VStack(alignment: .leading, spacing: 1) {
                title
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(subtitleIsLive ? Color.green : Color.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            buttons
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .quaternarySystemFill)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
    }

    // MARK: - Left: what streams

    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.gradient)
            if let chosen {
                AppGlyphIcon(app: chosen, size: 18)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 34, height: 34)
    }

    @ViewBuilder
    private var title: some View {
        let name = chosen?.name ?? host.displayName
        if apps.count > 1 {
            Menu {
                Picker("Game", selection: Binding(get: { chosen?.name ?? "" }, set: { chosenAppName = $0 })) {
                    ForEach(apps) { app in
                        Label { Text(app.name) } icon: { AppGlyphIcon(app: app) }
                            .tag(app.name)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 4) {
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.isStreaming)
            .accessibilityLabel("Game")
            .accessibilityValue(name)
            .help("Choose what to stream")
        } else {
            Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
    }

    private var subtitle: String {
        if streamingHere {
            if model.nativeStreamPictureInPicture, model.streamPhase == .streaming { return "Streaming in Picture in Picture" }
            return model.hostStatusLine(for: host.id)
        }
        if model.isStreaming { return "Another stream is running" }
        if resumes { return "Already running" }
        return model.hostStatusLine(for: host.id)
    }

    private var subtitleIsLive: Bool { streamingHere && model.streamPhase == .streaming }

    // MARK: - Right: the actions

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 8) {
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
            } else {
                PictureInPictureButton(entering: true) {
                    guard let chosen else { return }
                    model.pictureInPictureLaunchRequestedAt = Date()
                    model.requestStream(app: chosen, on: host)
                }
                .help("Stream in Picture in Picture")
                Button {
                    guard let chosen else { return }
                    model.requestStream(app: chosen, on: host)
                } label: {
                    Label(resumes ? "Resume" : "Stream", systemImage: "play.fill")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .disabled(chosen == nil || (model.isStreaming && !streamingHere))
    }
}

/// Picture in Picture as its own button: the system's PiP glyph in the accent
/// colour, square, beside Stream - one click streams straight into PiP.
private struct PictureInPictureButton: View {
    let entering: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: entering ? "pip.enter" : "pip.exit")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 20)
        }
        .accessibilityLabel(entering ? "Picture in Picture" : "Leave Picture in Picture")
    }
}
