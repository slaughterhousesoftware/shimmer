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
        let mark = mark
        Group {
            switch mark {
            case .playStation:
                Circle().fill(Self.colour(0x0070D1))
                    .overlay {
                        Image(systemName: "playstation.logo")
                            .resizable().scaledToFit()
                            .frame(width: size * 0.56, height: size * 0.56)
                            .foregroundStyle(.white)
                    }
            case .icon(.bazzite):
                // The colour artwork includes its own disc.
                Image("HostLogo-bazzite").renderingMode(.original).resizable().scaledToFit()
            case .icon(let icon):
                Circle().fill(Self.colour(icon.backgroundRGB))
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
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let status {
                HostConnectionBadge(status: status, size: size >= 48 ? 14 : 12)
            }
        }
        .help(statusText ?? host.displayName)
        .accessibilityLabel([Self.name(of: mark), statusText].compactMap { $0 }.joined(separator: ", "))
    }

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

/// A machine's status on its avatar's corner, ringed in the window colour.
struct HostConnectionBadge: View {
    let status: HostStatusIndicator
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(status == .online ? Color.green : status == .error ? .red : status == .neutral ? .secondary : .orange)
            .frame(width: size - 4, height: size - 4)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1))
    }
}
