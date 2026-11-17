//
//  HostSystemLogo.swift
//
//  A machine's system as a plain mark in the text colour - Tux, the Windows
//  squares, the Apple, the PlayStation logo (nearby machines not added yet) -
//  and as a round avatar for saved ones (HostAvatar). Each plain mark is
//  scaled so the four read the same size.
//

import AppKit
import SwiftUI

struct HostSystemLogo: View {
    private let fixedKind: HostSystemKind?
    private let host: Host?
    let size: CGFloat
    @AppStorage private var cachedKind: String

    /// A saved machine: its detected (cached) system.
    init(host: Host, size: CGFloat) {
        self.host = host
        self.fixedKind = nil
        self.size = size
        _cachedKind = AppStorage(wrappedValue: "", HostSystemKind.storageKey(for: host.id))
    }

    /// A machine not added yet (nearby): a kind settled by the caller.
    init(kind: HostSystemKind, size: CGFloat) {
        self.host = nil
        self.fixedKind = kind
        self.size = size
        _cachedKind = AppStorage(wrappedValue: "", "glimmer.hostSystem.-")
    }

    private var kind: HostSystemKind {
        if let fixedKind { return fixedKind }
        guard let host else { return .linux }
        if host.isPlayStation { return .playStation }
        return HostSystemKind(rawValue: cachedKind)
            ?? HostSystemKind.resolve(isPlayStation: false, ttl: nil, serverName: host.name)
    }

    var body: some View {
        Group {
            switch kind {
            case .playStation: mark(Image(systemName: "playstation.logo"), scale: 0.92)
            case .mac: mark(Image(systemName: "apple.logo"), scale: 0.78)
            case .windows: mark(Image("HostLogo-windows").renderingMode(.template), scale: 0.74)
            case .linux: mark(Image("HostLogo-linux").renderingMode(.template), scale: 0.9)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Self.name(of: kind))
    }

    private func mark(_ image: Image, scale: CGFloat) -> some View {
        image.resizable().scaledToFit().frame(width: size * scale, height: size * scale)
    }

    static func name(of kind: HostSystemKind) -> String {
        switch kind {
        case .linux: "Linux"
        case .windows: "Windows"
        case .mac: "Mac"
        case .playStation: "PlayStation"
        }
    }
}

/// A machine's icon: its platform's mark (see `body`), picked automatically
/// from the distro its name gives, else its detected system; a PS5 is
/// PlayStation.
struct HostAvatar: View {
    enum Mark: Equatable {
        case playStation
        case icon(HostIcon)
    }

    nonisolated static func mark(isPlayStation: Bool, serverName: String, kind: HostSystemKind) -> Mark {
        if isPlayStation || kind == .playStation { return .playStation }
        let named = HostIcon.suggested(for: serverName)
        if named != .computer, named != .automatic { return .icon(named) }
        switch kind {
        case .windows: return .icon(.windows)
        case .mac: return .icon(.macOS)
        case .linux, .playStation: return .icon(.linux)
        }
    }

    let host: Host
    var size: CGFloat = SettingsMetrics.sidebarIconSize
    var status: HostStatusIndicator?
    var statusText: String?
    @AppStorage private var cachedKind: String

    init(host: Host, size: CGFloat = SettingsMetrics.sidebarIconSize,
         status: HostStatusIndicator? = nil, statusText: String? = nil) {
        self.host = host
        self.size = size
        self.status = status
        self.statusText = statusText
        _cachedKind = AppStorage(wrappedValue: "", HostSystemKind.storageKey(for: host.id))
    }

    private var mark: Mark {
        let kind = HostSystemKind(rawValue: cachedKind)
            ?? HostSystemKind.resolve(isPlayStation: host.isPlayStation, ttl: nil, serverName: host.name)
        return Self.mark(isPlayStation: host.isPlayStation, serverName: host.name, kind: kind)
    }

    /// One icon library for every machine: Font Awesome's brand glyphs,
    /// drawn plain in the text colour - Tux for any Linux, the PlayStation,
    /// Windows and Apple marks - with no disc or tile behind them. Status is
    /// said in words beside the icon, not with a dot on it.
    var body: some View {
        Self.glyph(for: mark)
            .resizable()
            .scaledToFit()
            .frame(width: size * 0.72, height: size * 0.72)
            .frame(width: size, height: size)
            .foregroundStyle(.primary)
            .help(statusText ?? host.displayName)
            .accessibilityLabel([Self.name(of: mark), statusText].compactMap { $0 }.joined(separator: ", "))
    }

    static func glyph(for mark: Mark) -> Image {
        switch mark {
        case .playStation: Image("HostGlyph-playstation")
        case .icon(.windows): Image("HostGlyph-windows")
        case .icon(.macOS): Image("HostGlyph-apple")
        case .icon(.computer), .icon(.automatic): Image(systemName: "desktopcomputer")
        case .icon: Image("HostGlyph-linux")
        }
    }

    private static func name(of mark: Mark) -> String {
        switch mark {
        case .playStation: "PlayStation"
        case .icon(let icon): icon.title
        }
    }
}

/// Status colours for the dot before a machine's status.
enum HostConnectionBadge {
    static func colour(for status: HostStatusIndicator) -> Color {
        switch status {
        case .online: .green
        case .attention, .offline: .orange
        case .error: .red
        case .neutral: .secondary
        }
    }
}
