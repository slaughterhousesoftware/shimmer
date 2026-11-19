//
//  HostSystemLogo.swift
//
//  A machine's system as a round avatar: in its brand's colours for saved
//  machines (HostAvatar), in grey for nearby ones not added yet
//  (NearbyHostAvatar).
//

import AppKit
import SwiftUI

/// A machine not added yet (Nearby): the saved machines' avatar - same disc,
/// same mark, same size - in grey, the way the menu bar draws the servers not
/// in use (a 9% disc, a 50% mark, after Control Center's Focus list). It
/// reads as the same kind of thing, not added yet.
///
/// A PC's mark comes from pinging it, as a saved one's does (Windows answers
/// with a TTL of 128, Linux and macOS with 64): by name alone, anything not
/// called "Windows" or "Mac" drew Tux.
struct NearbyHostAvatar: View {
    let name: String
    let address: String
    let isPlayStation: Bool
    var size: CGFloat = SettingsMetrics.sidebarIconSize
    @State private var detected: (address: String, kind: HostSystemKind)?

    private var mark: HostAvatar.Mark {
        let kind = detected.flatMap { $0.address == address ? $0.kind : nil }
            ?? HostSystemKind.resolve(isPlayStation: isPlayStation, ttl: nil, serverName: name)
        return HostAvatar.mark(isPlayStation: isPlayStation, serverName: name, kind: kind)
    }

    var body: some View {
        HostAvatar.disc(mark, size: size, look: .off)
            .accessibilityLabel(HostAvatar.name(of: mark))
            .task(id: address) {
                guard !isPlayStation else { return }
                let kind = await HostSystemKind.detect(address: address, serverName: name)
                detected = (address, kind)
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

    /// A saved machine's mark, read once (no observation) - for AppKit
    /// drawing, such as the menu bar menu's Servers rows.
    static func mark(for host: Host) -> Mark {
        let kind = HostSystemKind.cached(hostID: host.id)
            ?? HostSystemKind.resolve(isPlayStation: host.isPlayStation, ttl: nil, serverName: host.name)
        return mark(isPlayStation: host.isPlayStation, serverName: host.name, kind: kind)
    }

    var body: some View {
        Self.disc(mark, size: size)
        .frame(width: size, height: size)
        // The status dot on the disc's rim (see `badge`), set into a 1.5 pt
        // gap cut out of the avatar - whatever is behind the row (the
        // selection plate, the sidebar) shows through, no drawn ring.
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
    ///
    /// Every mark is sized by one rule so none looks bigger than another:
    /// each asset is cropped to its own artwork (no built-in margin), then
    /// drawn at the same optical area - the geometric mean of its width and
    /// height is 54% of the disc - with its longest side capped at 66%, so a
    /// wide PlayStation mark and a tall Tux carry the same weight as a round
    /// Fedora. A mark that is nearly all ink (Windows' four panes) still
    /// looks heavier than a line drawing (Tux, Debian's swirl), so each is
    /// nudged by its measured ink coverage - `optical`, at most ±10%. Sizes
    /// and centring go by the ink itself, measured once per mark (`inkBox`),
    /// not by the artwork's frame: an SF Symbol's frame carries padding, and
    /// the ink's box is what the eye reads, so it lands exactly on the
    /// disc's centre.
    /// `look` .off is a nearby machine's grey (the menu bar's for servers
    /// not in use). Drawn by MenuHostMark as one bitmap per screen scale, its
    /// ink centred to the pixel in each: laid out by SwiftUI, a fractional
    /// mark frame was rounded to whole pixels and the Windows mark sat about
    /// a quarter of a pixel left on a 1x screen.
    static func disc(_ mark: Mark, size: CGFloat, look: MenuHostMark.Look = .current) -> some View {
        DiscImage(mark: mark, size: size, look: look)
    }

    private struct DiscImage: View {
        let mark: Mark
        let size: CGFloat
        let look: MenuHostMark.Look
        @Environment(\.colorScheme) private var colorScheme
        var body: some View {
            Image(nsImage: MenuHostMark.image(for: mark, look: look, dark: colorScheme == .dark, diameter: size))
                .frame(width: size, height: size)
        }
    }

    /// The ink's size for a disc `size` across: the geometric mean of its
    /// sides 54% of the disc (times `optical`), its longest side at most
    /// 66% of the disc whatever `optical` says, so a wide mark keeps clear
    /// of the rim.
    static func glyphFrame(aspect: CGFloat, size: CGFloat, optical: CGFloat = 1) -> CGSize {
        let side = size * 0.54 * optical
        var width = side * aspect.squareRoot()
        var height = side / aspect.squareRoot()
        let longest = max(width, height), cap = size * 0.66
        if longest > cap {
            width *= cap / longest
            height *= cap / longest
        }
        return CGSize(width: width, height: height)
    }

    /// A 7 pt dot (at 36 pt) centred on the disc's rim at 45° (r·cos45° ≈
    /// 12.7 pt each way), so it sits on the edge instead of over the mark.
    private var badge: CGFloat { size * 7 / 36 }
    private var badgeOffset: CGFloat { size * 12.7 / 36 }

    static func name(of mark: Mark) -> String {
        switch mark {
        case .playStation: "PlayStation"
        case .icon(let icon): icon.title
        }
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

extension HostAvatar {
    /// Debug: every mark on its disc, written as a PNG at 4x.
    @MainActor static func renderGallery(to url: URL) {
        let marks: [(String, Mark)] = HostIcon.allCases.filter { $0 != .automatic }.map { ($0.title, .icon($0)) }
            + [("PlayStation", .playStation)]
        let view = VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(stride(from: 0, to: marks.count, by: 6)), id: \.self) { start in
                HStack(spacing: 14) {
                    ForEach(start..<min(start + 6, marks.count), id: \.self) { i in
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                disc(marks[i].1, size: 36)
                                // As a nearby machine (NearbyHostAvatar).
                                disc(marks[i].1, size: 36, look: .off)
                            }
                            Text(marks[i].0).font(.system(size: 9)).lineLimit(1).frame(width: 76)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 4
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

/// Where a mark's ink sits inside its artwork, so it can be sized and
/// centred by what the eye sees rather than by its frame (an SF Symbol's
/// frame carries padding; bundled marks vary). Shared by the sidebar's
/// avatars and the Stream row's icon.
@MainActor enum InkMeasure {
    private static var cache: [String: (optical: CGFloat, inkBox: CGRect)] = [:]

    /// Measures a mark once (by `key`); see `scan`.
    static func measure(_ image: NSImage?, key: String) -> (optical: CGFloat, inkBox: CGRect) {
        if let cached = cache[key] { return cached }
        guard let image else { return (1, CGRect(x: 0, y: 0, width: 1, height: 1)) }
        let result = scan(image)
        cache[key] = result
        return result
    }

    /// Draws the mark into a 256-pixel RGBA bitmap and reads its alpha bytes
    /// directly: the ink's bounding box (`inkBox`, as fractions of the
    /// artwork, y down) and the share of that box that is ink (`optical`, a
    /// size nudge of at most ±10%). Reading pixel by pixel through
    /// NSBitmapImageRep took ~100 ms of a first visit to Servers or
    /// Controller; this takes well under a millisecond.
    static func scan(_ image: NSImage) -> (optical: CGFloat, inkBox: CGRect) {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        let side = 256
        guard image.size.width > 0, image.size.height > 0,
              // RGBA, not alpha-only: an SF Symbol draws nothing into an
              // alpha-only context.
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return (1, whole) }
        let scale = min(CGFloat(side) / image.size.width, CGFloat(side) / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(origin: .zero, size: drawn))
        NSGraphicsContext.restoreGraphicsState()
        // Rows run down from the top in memory; the drawing sits at the
        // bitmap's bottom-left.
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var inked = 0, minX = side, maxX = -1, minY = side, maxY = -1
        for y in 0..<side {
            let row = bytes + y * side * 4 + 3
            for x in 0..<side where row[x * 4] > 127 {
                inked += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard inked > 0 else { return (1, whole) }
        let boxW = CGFloat(maxX - minX + 1), boxH = CGFloat(maxY - minY + 1)
        let coverage = CGFloat(inked) / (boxW * boxH)
        let nudge = min(1.1, max(0.9, pow(0.55 / coverage, 0.2)))
        let top = CGFloat(side) - drawn.height
        let box = CGRect(x: CGFloat(minX) / drawn.width, y: (CGFloat(minY) - top) / drawn.height,
                         width: boxW / drawn.width, height: boxH / drawn.height)
        return (nudge, box)
    }
}
