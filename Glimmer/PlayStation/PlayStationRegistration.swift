//
//  PlayStationRegistration.swift
//
//  One-time registration with a PS5 on the LAN: the PSN account id plus the
//  8-digit code the console shows under Settings › System › Remote Play ›
//  Pair Device. The console answers with the keys every later session uses.
//

import Foundation

enum PlayStationRegistration {
    enum Failure: LocalizedError {
        case invalidAccountID, invalidPIN, rejected, unreachable, resting
        var errorDescription: String? {
            switch self {
            case .invalidAccountID: return "The PlayStation Network account ID is invalid. Sign in again."
            case .invalidPIN: return "The pairing code has 8 digits."
            case .rejected: return "The PS5 didn't take that code. Check that Pair Device is still open on the PS5, "
                + "then enter the code it shows now."
            case .unreachable: return "The PS5 isn't answering. Check that it's on, on this network, "
                + "and has Remote Play turned on."
            case .resting: return "The PS5 is in rest mode. Turn it on, then open Pair Device."
            }
        }
    }

    private final class Reply: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var host: ChiakiRegisteredHost?
        var finished = false
    }

    static func register(address: String, accountID: String, pin: String) async throws -> PlayStationConsole {
        guard let account = Data(base64Encoded: accountID), account.count == Int(CHIAKI_PSN_ACCOUNT_ID_SIZE) else {
            throw Failure.invalidAccountID
        }
        let digits = pin.filter(\.isNumber)
        guard digits.count == 8, let pinValue = UInt32(digits) else { throw Failure.invalidPIN }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try registerBlocking(address: address, account: account, accountID: accountID, pin: pinValue)
                })
            }
        }
    }

    /// Why pairing can't work right now, from the console's discovery answer
    /// (nil: no answer). Asked first, so a resting or silent console says so
    /// in two seconds instead of a refusal that blames the code, or a
    /// 20-second wait.
    static func precheck(_ status: PlayStationDiscovery.Status?) -> Failure? {
        guard let status else { return .unreachable }
        return status.power == .standby ? .resting : nil
    }

    private static func registerBlocking(address: String, account: Data, accountID: String,
                                         pin: UInt32) throws -> PlayStationConsole {
        PlayStationBackend.ensureLibInit()
        let log = UnsafeMutablePointer<ChiakiLog>.allocate(capacity: 1)
        log.initialize(to: ChiakiLog())
        PlayStationBackend.initLog(log, includeInfo: true)
        Diag.notice("PS5: registering with the console at \(address, privacy: .private)", "PlayStation")
        let hostCString = strdup(address)
        let regist = UnsafeMutablePointer<ChiakiRegist>.allocate(capacity: 1)
        regist.initialize(to: ChiakiRegist())
        defer {
            regist.deallocate()
            free(hostCString)
            log.deallocate()
        }

        var info = ChiakiRegistInfo()
        info.target = CHIAKI_TARGET_PS5_1
        info.host = UnsafePointer(hostCString)
        info.broadcast = false
        info.psn_online_id = nil
        info.pin = pin
        withUnsafeMutableBytes(of: &info.psn_account_id) { $0.copyBytes(from: account) }

        let reply = Reply()
        let ref = Unmanaged.passRetained(reply)
        defer { ref.release() }
        let err = chiaki_regist_start(regist, log, &info, { event, user in
            guard let event, let user else { return }
            let reply = Unmanaged<Reply>.fromOpaque(user).takeUnretainedValue()
            reply.lock.withLock {
                if event.pointee.type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS,
                   let host = event.pointee.registered_host {
                    reply.host = host.pointee
                }
                reply.finished = true
            }
            reply.done.signal()
        }, ref.toOpaque())
        guard err == CHIAKI_ERR_SUCCESS else { throw Failure.unreachable }
        let waited = reply.done.wait(timeout: .now() + 20)
        if waited == .timedOut { chiaki_regist_stop(regist) }
        chiaki_regist_fini(regist)

        let host = reply.lock.withLock { reply.host }
        guard let host else {
            Diag.notice("PS5: registration \(waited == .timedOut ? "timed out" : "was refused")", "PlayStation")
            throw waited == .timedOut ? Failure.unreachable : Failure.rejected
        }
        return console(from: host, address: address, accountID: accountID)
    }

    /// The console's registration reply as a saved console: MAC (lowercase hex,
    /// the discovery host-id), nickname, both keys and the protocol target.
    static func console(from host: ChiakiRegisteredHost, address: String, accountID: String) -> PlayStationConsole {
        let mac = withUnsafeBytes(of: host.server_mac) { $0.map { String(format: "%02x", $0) }.joined() }
        let nickname = withUnsafeBytes(of: host.server_nickname) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return PlayStationConsole(
            id: mac,
            nickname: nickname.isEmpty ? "PS5" : nickname,
            address: address,
            registKey: withUnsafeBytes(of: host.rp_regist_key) { Data($0) },
            rpKey: withUnsafeBytes(of: host.rp_key) { Data($0) },
            target: Int32(bitPattern: host.target.rawValue),
            accountID: accountID,
            registeredAt: Date())
    }
}
