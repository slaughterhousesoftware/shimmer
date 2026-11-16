//
//  DebugMockups.swift  (THROWAWAY - design spike for the per-PC settings page)
//
//  `--debug-snap=<host part>`: select that PC on the Servers tab, open the
//  main window, and after 3 s write the window (title bar included) to
//  /tmp/shimmer-snap-<host part>.png at the display's own scale.
//

import AppKit

@MainActor
enum DebugMockups {
    static func showIfRequested(model: AppModel) {
        guard let want = AppModel.debugKnob("snap")?.lowercased() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let host = model.hosts.first(where: { $0.displayName.lowercased().contains(want) }) else { return }
            model.selectHost(host)
            model.settingsTab = .computers
            AppDelegate.openMainWindow?()
            NSApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" && $0.isVisible }),
                      let frameView = window.contentView?.superview,
                      let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "/tmp/shimmer-snap-\(want).png"))
            }
        }
    }
}

import SwiftUI

/// Spike: the system a PC runs, as one of four plain logos.
enum SpikeSystemKind {
    case linux, windows, mac, playStation

    static func of(_ host: Host) -> Self {
        if host.isPlayStation { return .playStation }
        switch HostIcon.suggested(for: host.name) {
        case .windows: return .windows
        case .macOS: return .mac
        default: return .linux
        }
    }
}

struct SpikeSystemLogo: View {
    let host: Host
    let size: CGFloat
    private var coloured: Bool { AppModel.debugKnob("icons") == "color" }

    var body: some View {
        let kind = SpikeSystemKind.of(host)
        Group {
            switch kind {
            case .playStation:
                Image(systemName: "playstation.logo").resizable().scaledToFit()
                    .foregroundStyle(coloured ? Color(red: 0, green: 0.44, blue: 0.82) : .primary)
                    .frame(width: size * 0.92, height: size * 0.92)
            case .mac:
                Image(systemName: "apple.logo").resizable().scaledToFit()
                    .foregroundStyle(.primary)
                    .frame(width: size * 0.78, height: size * 0.78)
            case .windows:
                Image("HostLogo-windows").renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(coloured ? Color(red: 0, green: 0.47, blue: 0.83) : .primary)
                    .frame(width: size * 0.74, height: size * 0.74)
            case .linux:
                Image("HostLogo-linux").renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(.primary)
                    .frame(width: size * 0.9, height: size * 0.9)
            }
        }
        .frame(width: size, height: size)
    }
}

struct SpikeStatusDot: View {
    let status: HostStatusIndicator
    var body: some View {
        Circle().fill(status == .online ? Color.green : status == .neutral ? .secondary : .orange)
            .frame(width: 7, height: 7)
    }
}
