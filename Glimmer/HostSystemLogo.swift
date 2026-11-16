//
//  HostSystemLogo.swift
//
//  A machine's system as a plain mark in the text colour - Tux, the Windows
//  squares, the Apple, the PlayStation logo. No disc, no tile: machines are
//  not accounts. Each mark is scaled so the four read the same size.
//

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

/// A machine's reachability, as a small dot beside its name.
struct HostStatusDot: View {
    let status: HostStatusIndicator
    var body: some View {
        Circle()
            .fill(status == .online ? Color.green : status == .error ? .red : status == .neutral ? .secondary : .orange)
            .frame(width: 7, height: 7)
    }
}
