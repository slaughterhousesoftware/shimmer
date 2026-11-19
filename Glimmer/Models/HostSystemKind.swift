//
//  HostSystemKind.swift
//
//  The system a machine runs, which is all its logo shows: Linux, Windows,
//  Mac or PlayStation - detected, never picked. A PS5 is a PlayStation; a name
//  that says Windows or Mac is believed; otherwise Windows answers ping with a
//  TTL of 128 and Linux / macOS with 64. The answer is cached per host, so the
//  logo is right on the next launch before any ping.
//

import Foundation

enum HostSystemKind: String, Sendable {
    case linux, windows, mac, playStation

    static func resolve(isPlayStation: Bool, ttl: Int?, serverName: String) -> Self {
        if isPlayStation { return .playStation }
        switch HostIcon.suggested(for: serverName) {
        case .macOS: return .mac
        case .windows: return .windows
        default: break
        }
        if let ttl, ttl > 64 { return .windows }
        return .linux
    }

    static func storageKey(for hostID: String) -> String { "glimmer.hostSystem.\(hostID)" }

    static func cached(hostID: String) -> Self? {
        UserDefaults.standard.string(forKey: storageKey(for: hostID)).flatMap(Self.init)
    }

    /// The TTL in a `ping` reply line ("... ttl=64 time=2.8 ms"), or nil.
    static func ttl(fromPingOutput output: String) -> Int? {
        guard let range = output.range(of: "ttl=") else { return nil }
        return Int(output[range.upperBound...].prefix { $0.isNumber })
    }

    /// Ping `address` once (2 s) and settle the host's kind; cached. A host
    /// that doesn't answer keeps what was cached, or falls back by name.
    static func detect(host: Host, address: String) async -> Self {
        let ttl = host.isPlayStation ? nil : await pingTTL(address)
        let kind = resolve(isPlayStation: host.isPlayStation, ttl: ttl, serverName: host.name)
        if ttl != nil || host.isPlayStation || cached(hostID: host.id) == nil {
            UserDefaults.standard.set(kind.rawValue, forKey: storageKey(for: host.id))
            return kind
        }
        return cached(hostID: host.id) ?? kind
    }

    /// A machine not added yet (a nearby PC): ping it the same way, but cache
    /// nothing - it has no saved id yet. Until the answer, its name decides.
    static func detect(address: String, serverName: String) async -> Self {
        resolve(isPlayStation: false, ttl: await pingTTL(address), serverName: serverName)
    }

    private static func pingTTL(_ address: String) async -> Int? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/ping")
            process.arguments = ["-c", "1", "-t", "2", address]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: ttl(fromPingOutput: String(decoding: data, as: UTF8.self)))
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }
}
