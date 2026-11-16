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

