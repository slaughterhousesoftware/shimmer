//
//  PSNGameInfo.swift
//
//  The pure half of "what's running on the PS5": PSN presence and catalog
//  JSON, and the art cache. No network and no keychain here -
//  PSNMobileSession signs in, PlayStationNowPlaying asks.
//
//  A PS5 doesn't say what it is running on the LAN (discovery carries no
//  running-app header - checked with Apex Legends up); PSN does, as the
//  signed-in account's presence. Measured live 2026-11-18 (Apex Legends,
//  then TEKKEN 8, on PS5-661):
//    GET m.np.playstation.com/api/userProfile/v1/internal/users/me/basicPresences?type=primary
//    {"basicPresence": {"availability": "availableToPlay",
//       "primaryPlatformInfo": {"onlineStatus": "online", "platform": "PS5", ...},
//       "gameTitleInfoList": [{"npTitleId": "PPSA04873_00", "titleName": "Apex Legends",
//          "format": "PS5", "launchPlatform": "PS5", "conceptIconUrl": "https://image.api..."}]}}
//  gameTitleInfoList is absent with no game. conceptIconUrl was the very
//  URL the catalog lists as the concept's MASTER image (1024 px square).
//

import AppKit
import Foundation

/// A game the PSN account is playing, as presence names it.
struct PSNGame: Equatable, Sendable {
    /// "PPSA04873_00" - the catalog's form (an id without "_00" gets one).
    var titleID: String
    var name: String
    /// Square art straight from presence (conceptIconUrl, else npTitleIconUrl).
    var artURL: URL?
}

/// One account's presence.
struct PSNPresence: Equatable, Sendable {
    var online: Bool
    /// "PS5", "PS4", "ps4" (Sony's case varies) - upper-cased here.
    var platform: String?
    var games: [PSNGame]

    /// The game on a PS5: the account is online on a PS5 and the title was
    /// launched there (a PS4 game played on a PS5 counts). Anything else -
    /// offline, on a PS4, no game - is no game for the PS5's card.
    var ps5Game: PSNGame? {
        guard online, platform == "PS5" else { return nil }
        return games.first
    }

    enum ParseError: Error { case notPresence }

    static func parse(_ data: Data) throws -> PSNPresence {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let presence = root["basicPresence"] as? [String: Any]
        else { throw ParseError.notPresence }
        let platformInfo = presence["primaryPlatformInfo"] as? [String: Any]
        let online = (platformInfo?["onlineStatus"] as? String)?.lowercased() == "online"
        let platform = (platformInfo?["platform"] as? String)?.uppercased()
        let list = presence["gameTitleInfoList"] as? [[String: Any]] ?? []
        let games: [PSNGame] = list.compactMap { info in
            guard let rawID = info["npTitleId"] as? String, !rawID.isEmpty,
                  let name = (info["titleName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return nil }
            // Played where: launchPlatform (a PS4 title on a PS5 has format
            // PS4 and launches on PS5). Without it, the account's platform
            // decides (ps5Game).
            if let launched = (info["launchPlatform"] as? String)?.uppercased(), launched != "PS5" { return nil }
            let art = [info["conceptIconUrl"], info["npTitleIconUrl"]]
                .compactMap { ($0 as? String).flatMap(URL.init(string:)) }
                .first { $0.scheme == "https" }
            return PSNGame(titleID: PSNCatalog.conceptTitleID(rawID), name: name, artURL: art)
        }
        return PSNPresence(online: online, platform: platform, games: games)
    }
}

enum PSNCatalog {
    /// The catalog's title id: "PPSA04873" → "PPSA04873_00"; one that already
    /// carries a suffix is kept.
    static func conceptTitleID(_ raw: String) -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return id.contains("_") ? id : id + "_00"
    }

    /// The concept lookup (no sign-in needed). Country and language must be
    /// a pair Sony knows; US/en always is.
    static func conceptsURL(titleID: String, country: String, language: String) -> URL? {
        var c = URLComponents(string: "https://m.np.playstation.com/api/catalog/v2/titles/")
        guard let escaped = titleID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["_"]))
        else { return nil }
        c?.percentEncodedPath += escaped + "/concepts"
        c?.queryItems = [URLQueryItem(name: "country", value: country), URLQueryItem(name: "language", value: language),
                         URLQueryItem(name: "age", value: "99")]
        return c?.url
    }

    /// The concept's square MASTER image, or nil - including the catalog's
    /// "not found", an HTTP 200 whose entry carries an `errorCode`.
    static func masterImageURL(from data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let concepts: [[String: Any]] = (json as? [[String: Any]]) ?? ((json as? [String: Any]).map { [$0] } ?? [])
        for concept in concepts where concept["errorCode"] == nil {
            let images = (concept["media"] as? [String: Any])?["images"] as? [[String: Any]] ?? []
            if let master = images.first(where: { ($0["type"] as? String) == "MASTER" }),
               let url = (master["url"] as? String).flatMap(URL.init(string:)), url.scheme == "https" {
                return url
            }
        }
        return nil
    }

    /// Art is only ever fetched from Sony's own image hosts, over https.
    static func isSonyImage(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "image.api.playstation.com" || host.hasSuffix(".playstation.com")
            || host.hasSuffix(".playstation.net")
    }

    /// Sony's image server scales on request: 512 px is plenty for a 42 pt tile.
    static func sized(_ url: URL, width: Int = 512) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (c.queryItems ?? []).filter { $0.name != "w" }
        items.append(URLQueryItem(name: "w", value: String(width)))
        c.queryItems = items
        return c.url ?? url
    }
}

/// The claims of a JWT (unverified - only to read our own token's fields).
enum PSNJWT {
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Game art by title id: memory, then disk (Application Support/Shimmer/
/// PlayStation/Art), so a game's tile is drawn without a network trip after
/// its first sighting. Art for a title doesn't change in practice; entries
/// are kept until the folder is cleared.
final class PSNArtCache: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var memory: [String: Data] = [:]

    static let shared = PSNArtCache(directory: FileManager.default.urls(for: .applicationSupportDirectory,
                                                                         in: .userDomainMask)[0]
        .appendingPathComponent("Shimmer/PlayStation/Art", isDirectory: true))

    init(directory: URL) {
        self.directory = directory
    }

    /// A title id as a file name: letters, digits and "_" only, or nothing.
    static func fileName(for titleID: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(["_"])
        guard !titleID.isEmpty, titleID.count <= 32,
              titleID.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else { return nil }
        return titleID + ".img"
    }

    func data(for titleID: String) -> Data? {
        lock.lock()
        if let hit = memory[titleID] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let name = Self.fileName(for: titleID),
              let data = try? Data(contentsOf: directory.appendingPathComponent(name)), !data.isEmpty
        else { return nil }
        lock.lock()
        memory[titleID] = data
        lock.unlock()
        return data
    }

    func store(_ data: Data, for titleID: String) {
        guard let name = Self.fileName(for: titleID), !data.isEmpty else { return }
        lock.lock()
        memory[titleID] = data
        lock.unlock()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: [.atomic])
        } catch {
            Diag.warn("PSN art cache: could not save \(titleID): \(error.localizedDescription)", "PlayStation")
        }
    }
}

/// The card's tile from game art: the art filling the tile's rounded square,
/// the corner the app tiles use (MenuAppTile).
enum PSNGameTile {
    static func image(from data: Data, side: CGFloat = MenuAppTile.side) -> NSImage? {
        guard let art = NSImage(data: data), art.isValid, art.size.width > 0, art.size.height > 0 else { return nil }
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: side * 0.24, yRadius: side * 0.24).addClip()
            // Square art fills; anything else is cropped to its centre square.
            let s = art.size, edge = min(s.width, s.height)
            let source = NSRect(x: (s.width - edge) / 2, y: (s.height - edge) / 2, width: edge, height: edge)
            art.draw(in: rect, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true,
                     hints: [.interpolation: NSImageInterpolation.high.rawValue])
            return true
        }
    }
}
