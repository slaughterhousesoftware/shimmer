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
        #expect(HostAvatar.mark(isPlayStation: true, serverName: "PS5-482", kind: .playStation) == .playStation)
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

/// InkMeasure reads the drawn bitmap's bytes directly. The pixel-by-pixel
/// NSBitmapImageRep reading it replaced cost ~100 ms on a first visit to
/// Servers or Controller; the boxes must not move.
@MainActor
struct InkMeasureTests {
    /// The previous implementation, kept here as the reference.
    private static func reference(_ image: NSImage) -> (optical: CGFloat, inkBox: CGRect) {
        let side = 256
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let scale = min(CGFloat(side) / image.size.width, CGFloat(side) / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: drawn))
        NSGraphicsContext.restoreGraphicsState()
        var inked = 0, minX = side, maxX = -1, minY = side, maxY = -1
        for y in 0..<side { for x in 0..<side where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
            inked += 1; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        let boxW = CGFloat(maxX - minX + 1), boxH = CGFloat(maxY - minY + 1)
        let nudge = min(1.1, max(0.9, pow(0.55 / (CGFloat(inked) / (boxW * boxH)), 0.2)))
        let top = CGFloat(side) - drawn.height
        return (nudge, CGRect(x: CGFloat(minX) / drawn.width, y: (CGFloat(minY) - top) / drawn.height,
                              width: boxW / drawn.width, height: boxH / drawn.height))
    }

    private static var images: [(String, NSImage)] {
        var list: [(String, NSImage)] = []
        for name in ["playstation.logo", "xbox.logo", "gamecontroller.fill", "desktopcomputer", "apple.logo"] {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 64, weight: .regular)) { list.append((name, image)) }
        }
        for name in ["HostLogo-arch", "HostLogo-ubuntu", "HostLogo-bazzite-mark", "ControllerGlyph-ps5"] {
            if let image = NSImage(named: name) { list.append((name, image)) }
        }
        return list
    }

    @Test func boxesMatchTheReference() {
        let images = Self.images
        #expect(images.count >= 8)
        for (name, image) in images {
            let fast = InkMeasure.scan(image)
            let slow = Self.reference(image)
            #expect(abs(fast.optical - slow.optical) < 0.01, "\(name)")
            for (a, b) in [(fast.inkBox.minX, slow.inkBox.minX), (fast.inkBox.minY, slow.inkBox.minY),
                           (fast.inkBox.width, slow.inkBox.width), (fast.inkBox.height, slow.inkBox.height)] {
                #expect(abs(a - b) <= 1.5 / 256, "\(name)")
            }
        }
    }

    /// Faster than the pixel-by-pixel reading on the same machine and build:
    /// ~73x optimized (0.17 vs 12.5 ms an icon); tests run unoptimized,
    /// where the byte loop itself is slow, so the bar here is 3x.
    @Test func aMeasurementIsCheap() {
        let images = Self.images
        var start = Date()
        for (_, image) in images { _ = Self.reference(image) }
        let slow = Date().timeIntervalSince(start)
        start = Date()
        for (_, image) in images { _ = InkMeasure.scan(image) }
        let fast = Date().timeIntervalSince(start)
        #expect(fast * 3 < slow, "scan \(fast * 1000) ms vs reference \(slow * 1000) ms")
    }
}
