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

    /// Icon 28 pt (two lines of text tall), 10 pt to the text - the card's
    /// own inset, so the icon sits as far from the text as from the edge;
    /// the name at 13 pt and the second line at 11 pt secondary, 2 pt apart
    /// - System Settings' two-line rows. The text wins any squeeze before
    /// the buttons.
    private var leading: some View {
        HStack(spacing: RowIcon.gap) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                if showsChooser {
                    TitleChooser(title: title, apps: apps, chosen: app, choose: choose)
                        .disabled(model.isStreaming)
                } else {
                    Text(title).lineLimit(1)
                }
                // While live, a green dot leads the status line, as System
                // Settings marks a connected network; the words stay grey.
                HStack(spacing: 5) {
                    if subtitleIsLive {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
        }
    }

    private var icon: RowIcon {
        if host.isPlayStation { return RowIcon(symbol: "playstation.logo") }
        guard let app else { return RowIcon(symbol: "display") }
        switch app.glyph {
        case .symbol(let name): return RowIcon(symbol: name)
        case .asset(let name): return RowIcon(asset: name)
        }
    }

    private var title: String {
        host.isPlayStation ? "PlayStation 5" : (app?.name ?? "No app")
    }

    /// The row's second line: the stream while there is one, else what the
    /// row is (the console's home screen, or how many apps the PC offers).
    private var subtitle: String {
        if streamingHere {
            if case .streaming = model.streamPhase { return "Streaming" }
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

/// Under a machine's Stream row: what went wrong with its last stream, as a
/// sentence, with a way to put it away. System Settings words a row's problem
/// the same way: a yellow warning mark, the text in the secondary colour.
struct StreamFailureRow: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RowIcon.gap) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .frame(width: RowIcon.column)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("Dismiss", action: dismiss)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stream problem: \(message)")
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

/// A row's leading icon, sized by its ink: every mark the same optical size
/// (the geometric mean of its ink's sides 24 pt, its longest side at most
/// 28) and its ink centred in a 28 pt column. An SF Symbol drawn by frame
/// keeps its padding, which left a wide mark like the PlayStation logo
/// small and pushed the text away from it.
struct RowIcon: View {
    /// The column, and the gap to the text (a form row's own inset).
    static let column: CGFloat = 28
    static let gap: CGFloat = 10

    private let image: NSImage?
    private let key: String
    /// The ink's optical size and the column it's centred in (a row's icon:
    /// 24 in 28; a controller tile's logo is drawn smaller).
    private let side: CGFloat
    private let width: CGFloat

    init(symbol: String, side: CGFloat = 24, column: CGFloat = RowIcon.column) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 64, weight: .regular))
        key = "row-symbol:" + symbol
        self.side = side
        width = column
    }

    init(asset: String, side: CGFloat = 24, column: CGFloat = RowIcon.column) {
        image = NSImage(named: asset)
        key = "row-asset:" + asset
        self.side = side
        width = column
    }

    var body: some View {
        if let image, image.size.width > 0, image.size.height > 0 {
            let box = InkMeasure.measure(image, key: key).inkBox
            let ink = Self.inkSize(aspect: image.size.width / image.size.height * box.width / box.height,
                                   side: side, column: width)
            let frame = CGSize(width: ink.width / box.width, height: ink.height / box.height)
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .frame(width: frame.width, height: frame.height)
                .offset(x: (0.5 - box.midX) * frame.width, y: (0.5 - box.midY) * frame.height)
                .frame(width: width, height: width)
        } else {
            Color.clear.frame(width: width, height: width)
        }
    }

    static func inkSize(aspect: CGFloat, side: CGFloat = 24, column: CGFloat = RowIcon.column) -> CGSize {
        var width = side * aspect.squareRoot(), height = side / aspect.squareRoot()
        let longest = max(width, height)
        if longest > column { width *= column / longest; height *= column / longest }
        return CGSize(width: width, height: height)
    }
}
