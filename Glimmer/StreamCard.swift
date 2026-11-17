//
//  StreamCard.swift
//
//  The first row of a machine's page: what Stream launches, with Picture in
//  Picture and Stream beside it. A PS5's row is the console's home screen; a
//  PC's row is its chosen app, and when the PC has more than one, the app's
//  name is a menu like the page's others (its arrow in a grey square). The sidebar
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
            Spacer(minLength: 8)
            buttons
        }
        .padding(.vertical, 2)
        .hostContextMenu(host)
    }

    // MARK: Left: what streams

    private var showsChooser: Bool { !host.isPlayStation && apps.count > 1 }

    /// Icon 28 pt (two lines of text tall), 12 pt to the text; the name at
    /// 13 pt and the second line at 11 pt secondary, 2 pt apart - System
    /// Settings' two-line rows. The text wins any squeeze before the buttons.
    private var leading: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                if showsChooser {
                    TitleChooser(title: title, apps: apps, chosen: app, choose: choose)
                        .disabled(model.isStreaming)
                } else {
                    Text(title).lineLimit(1)
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(subtitleIsLive ? Color.green : Color.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
        }
    }

    /// The glyph drawn at the row's size: an SF Symbol takes its size from the
    /// font (AppGlyphIcon's size only frames bundled marks), so both are set.
    @ViewBuilder
    private var icon: some View {
        if host.isPlayStation {
            Image("HostGlyph-playstation").resizable().scaledToFit()
                .frame(width: 26, height: 26)
        } else if let app {
            AppGlyphIcon(app: app, size: 24)
                .font(.system(size: 21))
        } else {
            Image(systemName: "display").font(.system(size: 21))
        }
    }

    private var title: String {
        host.isPlayStation ? "PlayStation 5" : (app?.name ?? "No app")
    }

    /// The row's second line: the stream while there is one, else what the
    /// row is (the console's home screen, or how many apps the PC offers).
    private var subtitle: String {
        if streamingHere {
            if case .streaming = model.streamPhase {
                return model.activeStreamShorthand.map { "Streaming · \($0)" } ?? "Streaming"
            }
            return model.hostStatusLine(for: host.id)
        }
        if model.isStreaming { return "Another stream is live" }
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

/// Which of a PC's apps Stream launches: the row's title, with the pop-up
/// arrow in the same grey square as the page's other menus, dropping a
/// native menu of the apps (icons, the current one checked).
private struct TitleChooser: View {
    let title: String
    let apps: [LibraryApp]
    let chosen: LibraryApp?
    let choose: (String) -> Void
    @State private var anchor = MenuAnchor.Ref()

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                // The pop-up arrow as the page's other menus draw it (a
                // circle at 6% of the text colour, the arrow in the text
                // colour), sized to sit with 13 pt text: 18 pt, 5 pt off it.
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .contentShape(Rectangle())
            .background(MenuAnchor(ref: anchor))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Choose which app to stream")
        .accessibilityLabel("App to stream, \(chosen?.name ?? "none")")
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
        let below = view.isFlipped ? view.bounds.maxY + 6 : view.bounds.minY - 6
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX - 10, y: below), in: view)
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
