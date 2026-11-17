//
//  StreamCard.swift
//
//  The first row of a machine's page: what Stream launches, with Picture in
//  Picture and Stream beside it. A PS5's row is the console's home screen; a
//  PC's row is its chosen app, and when the PC has more than one, an apps
//  button joins Picture in Picture and Stream to choose another. The sidebar
//  names the machine and its status, so the page doesn't repeat them. While
//  this machine streams, the row shows the stream: its state, Picture in
//  Picture (or back to the window), End Stream.
//

import AppKit
import SwiftUI

struct StreamRow: View {
    @Environment(AppModel.self) private var model
    let host: Host
    /// The PC's apps (empty on a PS5).
    let apps: [LibraryApp]
    /// What Stream launches: the chosen app on a PC, nil on a PS5.
    let app: LibraryApp?
    let choose: (String) -> Void

    private var streamingHere: Bool { model.isStreaming && model.activeStreamHostID == host.id }
    private var connecting: Bool {
        if streamingHere, case .connecting = model.streamPhase { return true }
        return false
    }
    private var resumes: Bool { app.map { model.runningAppName == $0.name } ?? false }
    private var launchable: LibraryApp? { host.isPlayStation ? app ?? apps.first : app }

    var body: some View {
        HStack(spacing: 12) {
            leading
            Spacer(minLength: 12)
            buttons
        }
        .padding(.vertical, 2)
        .hostContextMenu(host)
    }

    // MARK: Left: what streams

    private var leading: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(subtitleIsLive ? Color.green : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if host.isPlayStation {
            Image("HostGlyph-playstation").resizable().scaledToFit()
        } else if let app {
            AppGlyphIcon(app: app, size: 18)
        } else {
            Image(systemName: "display")
        }
    }

    private var title: String {
        host.isPlayStation ? "PlayStation 5" : (app?.name ?? "No app")
    }

    /// The row's second line: the stream while there is one, else what the
    /// row is (the console's home screen, or how many apps the PC offers).
    private var subtitle: String {
        if streamingHere { return model.hostStatusLine(for: host.id) }
        if model.isStreaming { return "Another stream is running" }
        if resumes { return "Running" }
        if host.isPlayStation { return "Home screen" }
        return apps.count > 1 ? "\(apps.count) apps on \(host.displayName)" : "On \(host.displayName)"
    }

    private var subtitleIsLive: Bool { streamingHere && model.streamPhase == .streaming }

    // MARK: Right: the actions

    /// Plain Mac push buttons, as Tailscale uses ("Manage…", "Ping device"):
    /// no accent fill. End Stream is tinted red, as Rex's "Stop Server…".
    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 6) {
            if connecting {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancelConnect() }
            } else if streamingHere {
                if model.nativeStreamPictureInPicture {
                    Button { model.resumeStreamWindow() } label: { Image(systemName: "pip.exit") }
                        .help("Back to the stream window")
                        .accessibilityLabel("Leave Picture in Picture")
                } else {
                    Button { model.enterPictureInPicture() } label: { Image(systemName: "pip.enter") }
                        .help("Continue in Picture in Picture")
                        .accessibilityLabel("Picture in Picture")
                        .disabled(!model.activeStreamHasVideo)
                }
                Button("End Stream") { model.endStream() }
                    .tint(.red)
            } else {
                if !host.isPlayStation && apps.count > 1 {
                    AppsButton(apps: apps, chosen: app, choose: choose)
                }
                Button {
                    guard let launchable else { return }
                    model.pictureInPictureLaunchRequestedAt = Date()
                    model.requestStream(app: launchable, on: host)
                } label: {
                    Image(systemName: "pip.enter")
                }
                .help("Stream in Picture in Picture")
                .accessibilityLabel("Stream in Picture in Picture")
                Button(resumes ? "Resume" : "Stream") {
                    guard let launchable else { return }
                    model.requestStream(app: launchable, on: host)
                }
            }
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .disabled(launchable == nil || (model.isStreaming && !streamingHere))
    }
}

/// An invisible NSView behind a SwiftUI label, so an NSMenu can pop up
/// against it.
private struct MenuAnchor: NSViewRepresentable {
    final class Ref { weak var view: NSView? }
    let ref: Ref

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        ref.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { ref.view = view }
}

/// An NSMenuItem that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

/// A machine's status as words, after a small dot in its colour - the way
/// System Settings › Network lists "● Connected".
struct HostStatusText: View {
    let text: String
    let status: HostStatusIndicator

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(HostConnectionBadge.colour(for: status))
                .frame(width: 6, height: 6)
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}


/// Which of a PC's apps Stream launches: a button in the row's own group,
/// beside Picture in Picture and Stream, that drops a native menu of the
/// apps (icons, the current one checked) - the choice sits with the actions
/// it changes rather than squeezed in beside the name.
private struct AppsButton: View {
    let apps: [LibraryApp]
    let chosen: LibraryApp?
    let choose: (String) -> Void
    @State private var anchor = MenuAnchor.Ref()

    var body: some View {
        Button(action: showMenu) {
            Image(systemName: "square.grid.2x2").background(MenuAnchor(ref: anchor))
        }
        .help("Choose which app to stream")
        .accessibilityLabel("Choose app, \(chosen?.name ?? "none") selected")
    }

    private func showMenu() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        for app in apps {
            let item = ClosureMenuItem(title: app.name) { choose(app.name) }
            item.image = Self.image(for: app)
            item.state = app.name == chosen?.name ? .on : .off
            // macOS 27 hides menu images unless asked (Rex asks the same).
            if #available(macOS 27, *) { item.preferredImageVisibility = .visible }
            menu.addItem(item)
        }
        let below = view.isFlipped ? view.bounds.maxY + 8 : view.bounds.minY - 8
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX - 8, y: below), in: view)
    }

    private static func image(for app: LibraryApp) -> NSImage? {
        let image: NSImage?
        switch app.glyph {
        case .symbol(let name): image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .asset(let name): image = NSImage(named: name)
        }
        guard let image else { return nil }
        let sized = image.copy() as! NSImage
        let side: CGFloat = 16
        let scale = min(side / max(sized.size.width, 1), side / max(sized.size.height, 1))
        sized.size = NSSize(width: sized.size.width * scale, height: sized.size.height * scale)
        sized.isTemplate = true
        return sized
    }
}
