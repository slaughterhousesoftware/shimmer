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
    private let url: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shimmer", isDirectory: true)
            .appendingPathComponent("PlayStation", isDirectory: true)
        url = base.appendingPathComponent("consoles.json")
        load()
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
            Diag.error("PlayStation consoles file unreadable: \(error.localizedDescription)", "PlayStation")
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try Self.encoder.encode(consoles)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Diag.error("Could not save PlayStation consoles: \(error.localizedDescription)", "PlayStation")
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
