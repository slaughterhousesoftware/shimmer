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
    /// height is 54% of the disc - with its longest side capped at 69%, so a
    /// wide PlayStation mark and a tall Tux carry the same weight as a round
    /// Fedora. A mark that is nearly all ink (Windows' four panes) still
    /// looks heavier than a line drawing (Tux, Debian's swirl), so each is
    /// nudged by its measured ink coverage - `optical`, at most ±10%. And a
    /// lopsided mark (Debian's swirl is top-heavy, EndeavourOS bottom-heavy)
    /// looks off-centre when its box is centred, so each moves half-way from
    /// its box's centre towards its ink's centre of mass - `shift`.
    static func disc(_ mark: Mark, size: CGFloat) -> some View {
        let glyph = Glyph(mark)
        let frame = glyphFrame(aspect: glyph.aspect, size: size * glyph.optical)
        return Circle()
            .fill(glyph.fill)
            .overlay {
                glyph.image
                    .resizable()
                    .scaledToFit()
                    .frame(width: frame.width, height: frame.height)
                    .foregroundStyle(glyph.ink)
                    .offset(x: -glyph.shift.width * 0.5 * frame.width,
                            y: -glyph.shift.height * 0.5 * frame.height)
            }
            .frame(width: size, height: size)
    }

    static func glyphFrame(aspect: CGFloat, size: CGFloat) -> CGSize {
        let side = size * 0.54
        var width = side * aspect.squareRoot()
        var height = side / aspect.squareRoot()
        let longest = max(width, height), cap = size * 0.69
        if longest > cap {
            width *= cap / longest
            height *= cap / longest
        }
        return CGSize(width: width, height: height)
    }

    /// A mark's artwork, its proportions, and the colours it sits in.
    @MainActor private struct Glyph {
        let image: Image
        let aspect: CGFloat
        let fill: AnyShapeStyle
        let ink: Color
        /// The size nudge for how much of its box the mark inks: the 0.2th
        /// power of (typical coverage ÷ this mark's), within 0.9-1.1.
        let optical: CGFloat
        /// Where the ink's centre of mass sits from the box's centre, as a
        /// fraction of the box (positive: right / down).
        let shift: CGSize

        init(_ mark: Mark) {
            switch mark {
            case .playStation:
                self.init(symbol: "playstation.logo", fill: AnyShapeStyle(HostAvatar.colour(0x0070D1)))
            case .icon(.bazzite):
                // The press kit's gradient disc, its monogram solid white.
                self.init(asset: "HostLogo-bazzite-mark", fill: AnyShapeStyle(LinearGradient(
                    colors: [HostAvatar.colour(0x0047AB), HostAvatar.colour(0x8A2BE2)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)))
            case .icon(.chimeraOS):
                // Its only artwork is a detailed mascot that can't read at
                // sidebar size.
                self.init(symbol: "gamecontroller.fill", fill: AnyShapeStyle(HostAvatar.colour(HostIcon.chimeraOS.backgroundRGB)))
            case .icon(.macOS):
                self.init(symbol: "apple.logo", fill: AnyShapeStyle(HostAvatar.colour(HostIcon.macOS.backgroundRGB)))
            case .icon(.computer), .icon(.automatic):
                self.init(symbol: "desktopcomputer", fill: AnyShapeStyle(HostAvatar.colour(HostIcon.computer.backgroundRGB)))
            case .icon(let icon):
                self.init(asset: icon.assetName ?? "HostLogo-linux",
                          fill: AnyShapeStyle(HostAvatar.colour(icon.backgroundRGB)),
                          ink: icon == .linux ? .black : .white)
            }
        }

        private init(symbol: String, fill: AnyShapeStyle) {
            let ns = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            let size = ns?.size ?? CGSize(width: 1, height: 1)
            let measure = Self.measure(ns, key: "symbol:" + symbol)
            self.init(image: Image(systemName: symbol), aspect: size.width / max(size.height, 1), fill: fill,
                      ink: .white, optical: measure.optical, shift: measure.shift)
        }

        private init(asset: String, fill: AnyShapeStyle, ink: Color = .white) {
            let ns = NSImage(named: asset)
            let size = ns?.size ?? CGSize(width: 1, height: 1)
            let measure = Self.measure(ns, key: asset)
            self.init(image: Image(asset).renderingMode(.template),
                      aspect: size.width / max(size.height, 1), fill: fill, ink: ink,
                      optical: measure.optical, shift: measure.shift)
        }

        private init(image: Image, aspect: CGFloat, fill: AnyShapeStyle, ink: Color,
                     optical: CGFloat, shift: CGSize) {
            self.image = image
            self.aspect = aspect
            self.fill = fill
            self.ink = ink
            self.optical = optical
            self.shift = shift
        }

        @MainActor private static var measureCache: [String: (optical: CGFloat, shift: CGSize)] = [:]

        /// Measures the mark once: draws it into a 96-pixel square, then
        /// takes the share of its bounding box that is ink (for `optical`)
        /// and where the ink's centre of mass sits in that box (for `shift`).
        @MainActor private static func measure(_ image: NSImage?, key: String) -> (optical: CGFloat, shift: CGSize) {
            if let cached = measureCache[key] { return cached }
            let side = 96
            guard let image, let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0) else { return (1, .zero) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let scale = min(CGFloat(side) / max(image.size.width, 1), CGFloat(side) / max(image.size.height, 1))
            image.draw(in: NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale))
            NSGraphicsContext.restoreGraphicsState()
            var inked = 0, sumX = 0, sumY = 0, minX = side, maxX = -1, minY = side, maxY = -1
            for y in 0..<side { for x in 0..<side where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                inked += 1; sumX += x; sumY += y
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            } }
            guard inked > 0 else { return (1, .zero) }
            let boxW = CGFloat(maxX - minX + 1), boxH = CGFloat(maxY - minY + 1)
            let coverage = CGFloat(inked) / (boxW * boxH)
            let nudge = min(1.1, max(0.9, pow(0.55 / coverage, 0.2)))
            // colorAt's y runs down, as SwiftUI's offset does.
            let shift = CGSize(width: (CGFloat(sumX) / CGFloat(inked) - (CGFloat(minX) + boxW / 2 - 0.5)) / boxW,
                               height: (CGFloat(sumY) / CGFloat(inked) - (CGFloat(minY) + boxH / 2 - 0.5)) / boxH)
            measureCache[key] = (nudge, shift)
            return (nudge, shift)
        }
    }

    /// A 7 pt dot (at 36 pt) centred on the disc's rim at 45° (r·cos45° ≈
    /// 12.7 pt each way), so it sits on the edge instead of over the mark.
    private var badge: CGFloat { size * 7 / 36 }
    private var badgeOffset: CGFloat { size * 12.7 / 36 }

    private static func name(of mark: Mark) -> String {
        switch mark {
        case .playStation: "PlayStation"
        case .icon(let icon): icon.title
        }
    }

    fileprivate static func colour(_ rgb: UInt32) -> Color {
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
                            disc(marks[i].1, size: 36)
                            Text(marks[i].0).font(.system(size: 9)).lineLimit(1).frame(width: 64)
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
