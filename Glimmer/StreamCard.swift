//
//  StreamCard.swift
//
//  The first row of a machine's page: what Stream launches, with Picture in
//  Picture and Stream beside it. A PS5's row is the console's home screen; a
//  PC's row is its chosen app, and when the PC has more than one, the row's
//  left side is the chooser - icon, name and a pop-up chevron in one target
//  that lights on hover, the way Xcode's run destination does. The sidebar
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
            if !host.isPlayStation && apps.count > 1 {
                AppChooser(apps: apps, chosen: app, choose: choose) { leading(showsChevron: true) }
                    .disabled(model.isStreaming)
            } else {
                leading(showsChevron: false)
            }
            Spacer(minLength: 12)
            buttons
        }
        .padding(.vertical, 2)
        .hostContextMenu(host)
    }

    // MARK: Left: what streams

    private func leading(showsChevron: Bool) -> some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title).lineLimit(1)
                    if showsChevron {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
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

/// A PC's app chooser: the row's icon, name and chevron as one pop-up target.
/// It reads as text until you point at it, then lights a soft plate, as
/// Xcode's run destination and Finder's path bar do; a click drops a native
/// menu of the apps under it, the current one checked. (Not a SwiftUI Menu:
/// with a custom label style its items come out greyed, or it won't open.)
private struct AppChooser<Label: View>: View {
    let apps: [LibraryApp]
    let chosen: LibraryApp?
    let choose: (String) -> Void
    @ViewBuilder var label: Label
    @State private var anchor = MenuAnchor.Ref()

    var body: some View {
        Button(action: showMenu) {
            label.background(MenuAnchor(ref: anchor))
        }
        .buttonStyle(ChooserButtonStyle())
        .fixedSize()
        .accessibilityLabel("App to stream: \(chosen?.name ?? "none")")
        .accessibilityHint("Shows the apps on this PC")
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
        // Just under the label, its left edge on the icon's.
        let below = view.isFlipped ? view.bounds.maxY + 5 : view.bounds.minY - 5
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX - 4, y: below), in: view)
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

private struct ChooserButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChooserPlate(configuration: configuration)
    }

    private struct ChooserPlate: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(plateOpacity)))
                // The plate sits outside the label's own bounds, so the icon
                // still lines up with a PS5 row's.
                .padding(.horizontal, -6)
                .padding(.vertical, -4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var plateOpacity: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.1 }
            return hovering ? 0.06 : 0
        }
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
