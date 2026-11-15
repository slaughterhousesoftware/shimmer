//
//  PlayStationDiscovery.swift
//
//  PS5 discovery (power state, running game) and wake, over libchiaki. Probes go
//  unicast to the console's address so they also cross a Tailscale subnet route,
//  which does not carry broadcasts.
//

import Foundation

enum PlayStationDiscovery {
    struct Status: Equatable, Sendable {
        enum Power: Sendable { case ready, standby, unknown }
        var power: Power
        var hostName: String?
        var hostID: String?
        var systemVersion: String?
        var runningApp: String?
    }

    private final class Reply: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var status: Status?
    }

    nonisolated(unsafe) private static let log: UnsafeMutablePointer<ChiakiLog> = {
        let log = UnsafeMutablePointer<ChiakiLog>.allocate(capacity: 1)
        log.initialize(to: ChiakiLog())
        chiaki_log_init(log, UInt32(CHIAKI_LOG_ERROR.rawValue), nil, nil)
        return log
    }()

    /// One status probe; nil when the console does not answer (off, or not
    /// reachable from here).
    static func probe(address: String, timeout: TimeInterval = 2) async -> Status? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: probeBlocking(address: address, timeout: timeout))
            }
        }
    }

    /// A PS5 that answered a LAN scan.
    struct Found: Identifiable, Hashable, Sendable {
        /// Discovery host-id: the console's MAC, uppercase hex.
        var id: String
        var name: String
        var address: String
        var ready: Bool
    }

    private final class ScanReply: @unchecked Sendable {
        let lock = NSLock()
        var found: [String: Found] = [:]
    }

    /// Broadcast a search on the LAN and collect every PS5 that answers.
    static func scan(timeout: TimeInterval = 1.5) async -> [Found] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: scanBlocking(timeout: timeout))
            }
        }
    }

    private static func scanBlocking(timeout: TimeInterval) -> [Found] {
        let discovery = UnsafeMutablePointer<ChiakiDiscovery>.allocate(capacity: 1)
        let thread = UnsafeMutablePointer<ChiakiDiscoveryThread>.allocate(capacity: 1)
        defer {
            discovery.deallocate()
            thread.deallocate()
        }
        guard chiaki_discovery_init(discovery, log, sa_family_t(AF_INET)) == CHIAKI_ERR_SUCCESS else { return [] }
        defer { chiaki_discovery_fini(discovery) }
        let reply = ScanReply()
        let ref = Unmanaged.passRetained(reply)
        defer { ref.release() }
        guard chiaki_discovery_thread_start(thread, discovery, { host, user in
            guard let host, let user else { return }
            let h = host.pointee
            guard let type = h.host_type.map({ String(cString: $0) }), type == "PS5",
                  let id = h.host_id.map({ String(cString: $0) }),
                  let address = h.host_addr.map({ String(cString: $0) }) else { return }
            let reply = Unmanaged<ScanReply>.fromOpaque(user).takeUnretainedValue()
            let found = Found(id: id, name: h.host_name.map { String(cString: $0) } ?? "PS5",
                              address: address, ready: h.state == CHIAKI_DISCOVERY_HOST_STATE_READY)
            reply.lock.withLock { reply.found[id] = found }
        }, ref.toOpaque()) == CHIAKI_ERR_SUCCESS else { return [] }
        defer { chiaki_discovery_thread_stop(thread) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(CHIAKI_DISCOVERY_PORT_PS5).bigEndian)
        addr.sin_addr.s_addr = INADDR_BROADCAST
        let version = strdup(CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS5)
        defer { free(version) }
        var packet = ChiakiDiscoveryPacket()
        packet.cmd = CHIAKI_DISCOVERY_CMD_SRCH
        packet.protocol_version = version
        for _ in 0..<2 {
            _ = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    chiaki_discovery_send(discovery, &packet, $0, MemoryLayout<sockaddr_in>.size)
                }
            }
            Thread.sleep(forTimeInterval: timeout / 2)
        }
        return reply.lock.withLock { Array(reply.found.values) }.sorted { $0.name < $1.name }
    }

    /// Poll until the console reports "ready" or `timeout` passes.
    static func waitUntilReady(address: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if await probe(address: address, timeout: 1.5)?.power == .ready {
                // The console answers discovery a moment before Remote Play
                // accepts a session.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    /// Send the wake packet. Fire-and-forget; poll with waitUntilReady.
    static func wake(console: PlayStationConsole) {
        guard let credential = console.wakeCredential else {
            Diag.error("PS5: no wake credential in the registration", "PlayStation")
            return
        }
        let err = console.address.withCString { chiaki_discovery_wakeup(log, nil, $0, credential, true) }
        if err != CHIAKI_ERR_SUCCESS {
            Diag.error("PS5: wake failed - \(String(cString: chiaki_error_string(err)))", "PlayStation")
        }
    }

    private static func probeBlocking(address: String, timeout: TimeInterval) -> Status? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(CHIAKI_DISCOVERY_PORT_PS5).bigEndian)
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { return nil }

        let discovery = UnsafeMutablePointer<ChiakiDiscovery>.allocate(capacity: 1)
        let thread = UnsafeMutablePointer<ChiakiDiscoveryThread>.allocate(capacity: 1)
        defer {
            discovery.deallocate()
            thread.deallocate()
        }
        guard chiaki_discovery_init(discovery, log, sa_family_t(AF_INET)) == CHIAKI_ERR_SUCCESS else { return nil }
        defer { chiaki_discovery_fini(discovery) }

        let reply = Reply()
        let ref = Unmanaged.passRetained(reply)
        defer { ref.release() }
        let started = chiaki_discovery_thread_start_oneshot(thread, discovery, { host, user in
            guard let host, let user else { return }
            let reply = Unmanaged<Reply>.fromOpaque(user).takeUnretainedValue()
            let h = host.pointee
            let power: Status.Power
            switch h.state {
            case CHIAKI_DISCOVERY_HOST_STATE_READY: power = .ready
            case CHIAKI_DISCOVERY_HOST_STATE_STANDBY: power = .standby
            default: power = .unknown
            }
            let status = Status(
                power: power,
                hostName: h.host_name.map { String(cString: $0) },
                hostID: h.host_id.map { String(cString: $0) },
                systemVersion: h.system_version.map { String(cString: $0) },
                runningApp: h.running_app_name.map { String(cString: $0) })
            reply.lock.withLock { reply.status = status }
            reply.done.signal()
        }, ref.toOpaque())
        guard started == CHIAKI_ERR_SUCCESS else { return nil }
        defer { chiaki_discovery_thread_stop(thread) }

        let version = strdup(CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS5)
        defer { free(version) }
        var packet = ChiakiDiscoveryPacket()
        packet.cmd = CHIAKI_DISCOVERY_CMD_SRCH
        packet.protocol_version = version

        let attempts = 3
        for _ in 0..<attempts {
            _ = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    chiaki_discovery_send(discovery, &packet, $0, MemoryLayout<sockaddr_in>.size)
                }
            }
            if reply.done.wait(timeout: .now() + timeout / Double(attempts)) == .success {
                return reply.lock.withLock { reply.status }
            }
        }
        return nil
    }
}
