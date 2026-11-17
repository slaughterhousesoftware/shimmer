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

/// A machine as a round avatar, in the shape of Tailscale's account rows:
/// a brand-coloured disc with its system's mark, and its status as a badge.
/// Picked automatically - the distro its name gives (Bazzite's own artwork),
/// else its detected system; a PS5 is PlayStation.
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

    var body: some View {
        Self.disc(mark, size: size)
        .frame(width: size, height: size)
        // Tailscale's status dot (measured off its Settings window at 2x): a
        // 10 pt dot centred 10 pt right of and below a 36 pt avatar's centre,
        // set into a 1.5 pt gap cut out of the avatar - whatever is behind the
        // row (the selection plate, the sidebar) shows through, no drawn ring.
        .mask {
            if status != nil {
                ZStack {
                    Rectangle()
                    Circle()
                        .frame(width: badge + 3, height: badge + 3)
                        .position(x: size / 2 + badgeOffset, y: size / 2 + badgeOffset)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            } else {
                Rectangle()
            }
        }
        .overlay {
            if let status {
                Circle()
                    .fill(HostConnectionBadge.colour(for: status))
                    .frame(width: badge, height: badge)
                    .position(x: size / 2 + badgeOffset, y: size / 2 + badgeOffset)
            }
        }
        .help(statusText ?? host.displayName)
        .accessibilityLabel([Self.name(of: mark), statusText].compactMap { $0 }.joined(separator: ", "))
    }

    /// The disc for a mark: the platform's colour with its mark in white.
    @ViewBuilder
    static func disc(_ mark: Mark, size: CGFloat) -> some View {
        switch mark {
        case .playStation:
            Circle().fill(colour(0x0070D1))
                .overlay {
                    Image(systemName: "playstation.logo")
                        .resizable().scaledToFit()
                        .frame(width: size * 0.56, height: size * 0.56)
                        .foregroundStyle(.white)
                }
        case .icon(.bazzite):
            // The official colour artwork, which includes its own disc, with
            // its translucent monogram made solid white so it reads at 36 pt.
            Image("HostLogo-bazzite").renderingMode(.original).resizable().scaledToFit()
        case .icon(.chimeraOS), .icon(.computer), .icon(.automatic):
            // ChimeraOS's only artwork is a detailed mascot that can't read at
            // this size, so it gets a controller; a plain PC a computer.
            Circle().fill(colour(mark == .icon(.chimeraOS) ? HostIcon.chimeraOS.backgroundRGB
                                                            : HostIcon.computer.backgroundRGB))
                .overlay {
                    Image(systemName: mark == .icon(.chimeraOS) ? "gamecontroller.fill" : "desktopcomputer")
                        .resizable().scaledToFit()
                        .frame(width: size * 0.52, height: size * 0.52)
                        .foregroundStyle(.white)
                }
        case .icon(let icon):
            Circle().fill(colour(icon.backgroundRGB))
                .overlay {
                    Group {
                        if icon == .macOS {
                            Image(systemName: "apple.logo").resizable().scaledToFit()
                                .frame(width: size * 0.5, height: size * 0.5)
                        } else if let asset = icon.assetName {
                            Image(asset)
                                .renderingMode(icon == .chimeraOS ? .original : .template)
                                .resizable().scaledToFit()
                                .frame(width: size * 0.69, height: size * 0.69)
                        }
                    }
                    .foregroundStyle(icon == .linux ? .black : .white)
                }
        }
    }

    private var badge: CGFloat { size * 10 / 36 }
    private var badgeOffset: CGFloat { size * 10 / 36 }

    private static func name(of mark: Mark) -> String {
        switch mark {
        case .playStation: "PlayStation"
        case .icon(let icon): icon.title
        }
    }

    private static func colour(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
              blue: Double(rgb & 255) / 255)
    }
}

/// Status colours for a machine's avatar dot.
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
