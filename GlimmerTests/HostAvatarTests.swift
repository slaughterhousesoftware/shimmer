//
//  HostAvatarTests.swift
//
//  A machine's round avatar: the distro its name gives (Bazzite's own
//  artwork), else its detected system; a PS5 is always PlayStation.
//

import AppKit
import Testing
@testable import Glimmer

struct HostAvatarTests {
    @Test func ps5IsPlayStation() {
        #expect(HostAvatar.mark(isPlayStation: true, serverName: "PS5-661", kind: .playStation) == .playStation)
    }
    @Test func distroNameWins() {
        #expect(HostAvatar.mark(isPlayStation: false, serverName: "bazzite", kind: .linux) == .icon(.bazzite))
    }
    @Test func unknownNameFallsBackToDetectedSystem() {
        #expect(HostAvatar.mark(isPlayStation: false, serverName: "DESKTOP-ABC123", kind: .windows) == .icon(.windows))
        #expect(HostAvatar.mark(isPlayStation: false, serverName: "gaming", kind: .linux) == .icon(.linux))
        #expect(HostAvatar.mark(isPlayStation: false, serverName: "studio", kind: .mac) == .icon(.macOS))
    }
}

/// A row's leading icon: every mark the same optical size, a wide one
/// stopped at the 28 pt column, its ink centred so the gap before it
/// matches the gap after.
@MainActor
struct RowIconTests {
    @Test func roundMarkIs24Square() {
        #expect(RowIcon.inkSize(aspect: 1) == CGSize(width: 24, height: 24))
    }
    @Test func wideMarkFillsTheColumn() {
        let wide = RowIcon.inkSize(aspect: 1.6)
        #expect(abs(wide.width - 28) < 0.01)
        #expect(abs(wide.width / wide.height - 1.6) < 0.01)
    }
    @Test func gapMatchesAFormRowsInset() {
        #expect(RowIcon.gap == 10)
        #expect(RowIcon.column == 28)
    }
    /// The PlayStation symbol's ink, not its padded frame, is what's sized.
    @Test func playStationLogoInkIsMeasuredTight() {
        let image = NSImage(systemSymbolName: "playstation.logo", accessibilityDescription: nil)
        let box = InkMeasure.measure(image, key: "test:playstation.logo").inkBox
        #expect(box.width > 0.5 && box.width <= 1)
        #expect(box.minX >= 0 && box.maxX <= 1.001)
    }
}
