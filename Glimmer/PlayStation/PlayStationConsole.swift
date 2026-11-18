//
//  PlayStationConsole.swift
//
//  A PS5 registered for Remote Play, and the store that keeps the registrations.
//
//  A registration is the pair of keys the console hands out once (regist key +
//  rp_key "morning") for this PSN account. The keys work from any Mac signed in
//  as that account, so the store is a plain file the user can copy between Macs:
//  ~/Library/Application Support/Shimmer/PlayStation/consoles.json, mode 0600,
//  the same treatment as the Sunshine client identity next to it.
//

import Foundation

struct PlayStationConsole: Codable, Identifiable, Hashable, Sendable {
    /// The console's MAC address in lowercase hex ("aabbccddeeff") - also its
    /// discovery host-id, so a discovery reply finds its registration.
    var id: String
    var nickname: String
    /// LAN IP (or a Tailscale subnet-routed IP). Updated from discovery.
    var address: String
    /// rp_regist_key, CHIAKI_SESSION_AUTH_SIZE (16) bytes, zero padded.
    var registKey: Data
    /// rp_key, 16 bytes (libchiaki's ConnectInfo.morning).
    var rpKey: Data
    /// ChiakiTarget raw value (PS5 = 1000100).
    var target: Int32
    /// PSN account the registration belongs to (base64, 8 bytes).
    var accountID: String?
    var registeredAt: Date?
    var lastStreamed: Date?

    /// Host id used where the app treats a console as a host (library, menu).
    var hostID: String { "ps5-\(id)" }

    /// The wake credential: the regist key read as a hex string (chiaki's
    /// discovery wakeup takes it as an integer).
    var wakeCredential: UInt64? {
        let key = registKey.prefix { $0 != 0 }
        guard !key.isEmpty, let hex = String(data: key, encoding: .ascii) else { return nil }
        return UInt64(hex, radix: 16)
    }
}

/// File-backed list of registered consoles. Main-actor: the UI owns it.
@MainActor
final class PlayStationStore {
    static let shared = PlayStationStore()

    private(set) var consoles: [PlayStationConsole] = []
    /// The PSN account new registrations are made for (account.json).
    private(set) var account: PlayStationAccount.Identity?
    private let url: URL
    private let accountURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shimmer", isDirectory: true)
            .appendingPathComponent("PlayStation", isDirectory: true)
        url = base.appendingPathComponent("consoles.json")
        accountURL = base.appendingPathComponent("account.json")
        load()
        if let data = try? Data(contentsOf: accountURL) {
            account = try? Self.decoder.decode(PlayStationAccount.Identity.self, from: data)
        }
        // A registration made elsewhere (ps5ctl, another Mac) still names its account.
        if account == nil, let id = consoles.compactMap(\.accountID).first {
            account = PlayStationAccount.Identity(accountID: id, onlineID: nil)
        }
    }

    func setAccount(_ identity: PlayStationAccount.Identity) {
        account = identity
        write(try? Self.encoder.encode(identity), to: accountURL)
    }

    /// A discovered console is ours when its host-id or its name matches a
    /// registration (the name covers a PS5 that reports a new host-id wired).
    func isRegistered(hostID discoveryHostID: String, name: String? = nil) -> Bool {
        consoles.contains { $0.id == discoveryHostID.lowercased() || (name != nil && $0.nickname == name) }
    }

    func console(hostID: String) -> PlayStationConsole? {
        consoles.first { $0.hostID == hostID }
    }

    func upsert(_ console: PlayStationConsole) {
        if let index = consoles.firstIndex(where: { $0.id == console.id }) {
            consoles[index] = console
        } else {
            consoles.append(console)
        }
        save()
    }

    func remove(id: String) {
        consoles.removeAll { $0.id == id }
        save()
    }

    func updateAddress(id: String, address: String) {
        guard let index = consoles.firstIndex(where: { $0.id == id }), consoles[index].address != address else { return }
        consoles[index].address = address
        save()
    }

    func markStreamed(id: String) {
        guard let index = consoles.firstIndex(where: { $0.id == id }) else { return }
        consoles[index].lastStreamed = Date()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            consoles = try Self.decoder.decode([PlayStationConsole].self, from: data)
        } catch {
            // Keep it. The list is empty now, and the next registration would
            // have saved a one-console file over this one - every other
            // console's registration key gone with it. Moved aside, it can be
            // repaired or read by a build that understands it.
            let aside = Self.asideURL(for: url)
            let moved = (try? FileManager.default.moveItem(at: url, to: aside)) != nil
            Diag.error("PlayStation consoles file unreadable (\(error.localizedDescription)) - "
                + (moved ? "kept as \(aside.lastPathComponent)" : "could not move it aside"), "PlayStation")
        }
    }

    /// Where an unreadable store is kept: beside the original, stamped.
    static func asideURL(for file: URL, now: Date = Date()) -> URL {
        let stamp = Int(now.timeIntervalSince1970)
        return file.deletingLastPathComponent()
            .appendingPathComponent("\(file.deletingPathExtension().lastPathComponent).unreadable-\(stamp).json")
    }

    private func save() {
        write(try? Self.encoder.encode(consoles), to: url)
    }

    private func write(_ data: Data?, to file: URL) {
        guard let data else { return }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            Diag.error("Could not save \(file.lastPathComponent): \(error.localizedDescription)", "PlayStation")
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
