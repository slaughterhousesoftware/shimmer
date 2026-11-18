import Foundation
import Testing
@testable import Glimmer

/// Inputs the app does not control - bytes from whatever answers a port, a
/// file on disk, a clock read a moment before a lock - that used to crash it,
/// lose data, or end a healthy stream.
struct HardeningTests {

    /// "Content-Length:" with no value split into one piece, and the parser
    /// indexed the second: a crash on any responder that sent it.
    @Test func anEmptyContentLengthIsNoHeaderNotACrash() throws {
        func length(_ header: String) throws -> Int? {
            try ControlTransport.contentLengthForTesting(in: Data(header.utf8))
        }
        #expect(try length("HTTP/1.1 200 OK\r\nContent-Length:\r\n") == nil)
        #expect(try length("HTTP/1.1 200 OK\r\nContent-Length: \r\n") == nil)
        #expect(try length("HTTP/1.1 200 OK\r\nContent-Length: abc\r\n") == nil)
        #expect(try length("HTTP/1.1 200 OK\r\nContent-Length: -5\r\n") == nil)
        #expect(try length("HTTP/1.1 200 OK\r\nContent-Length: 42\r\n") == 42)
        #expect(try length("HTTP/1.1 200 OK\r\ncontent-length:7\r\nX: y\r\n") == 7)
        #expect(try length("HTTP/1.1 200 OK\r\nX: y\r\n") == nil)
    }

    /// The control loop reads its clock, then takes the lock; an ACK stamped
    /// in between is a millisecond in the future. Wrapping subtraction made
    /// that 49 days of silence - a "dead peer" on a healthy link.
    @Test func aStampFromAMomentLaterIsZeroElapsedNotFortyNineDays() {
        #expect(Enet.elapsedMs(now: 1000, since: 1001) == 0)
        #expect(Enet.elapsedMs(now: 1000, since: 1000) == 0)
        #expect(Enet.elapsedMs(now: 1000, since: 400) == 600)
        // The 32-bit clock still wraps correctly the other way.
        #expect(Enet.elapsedMs(now: 5, since: UInt32.max - 4) == 10)
    }

    /// The first resend comes one timeout after the send, then backs off.
    /// Shifting by the attempt count (which starts at 1) made it two.
    @Test func theFirstResendWaitsOneTimeout() {
        #expect(Enet.retransmitTimeoutMs(baseMs: 30, attempts: 1) == 30)
        #expect(Enet.retransmitTimeoutMs(baseMs: 30, attempts: 2) == 60)
        #expect(Enet.retransmitTimeoutMs(baseMs: 30, attempts: 3) == 120)
        // Capped: a long outage doesn't push resends minutes apart.
        #expect(Enet.retransmitTimeoutMs(baseMs: 30, attempts: 9) == 480)
        #expect(Enet.retransmitTimeoutMs(baseMs: 30, attempts: 0) == 30)
    }

    /// Ten seconds without a frame while the control link has been quiet for
    /// 5-10 s is a dropping link: reconnect. It used to end the stream,
    /// seconds before the dead-peer reconnect would have begun.
    @Test func aStallOnAQuietLinkReconnectsInsteadOfEnding() {
        typealias S = StreamSession
        #expect(S.watchdogTimeoutAction(neverDecodedFirstFrame: false, sinceLastAckMs: 100,
                                        reachedLiveState: true, canReconnectInPlace: true) == .hold)
        #expect(S.watchdogTimeoutAction(neverDecodedFirstFrame: false, sinceLastAckMs: 7_000,
                                        reachedLiveState: true, canReconnectInPlace: true) == .reconnect)
        // A PS5 session has nothing to reconnect to; a stream that never
        // showed a frame is a failed start, not an interruption.
        #expect(S.watchdogTimeoutAction(neverDecodedFirstFrame: false, sinceLastAckMs: nil,
                                        reachedLiveState: true, canReconnectInPlace: false) == .stop)
        #expect(S.watchdogTimeoutAction(neverDecodedFirstFrame: true, sinceLastAckMs: 100,
                                        reachedLiveState: false, canReconnectInPlace: true) == .stop)
        #expect(S.watchdogTimeoutAction(neverDecodedFirstFrame: false, sinceLastAckMs: 7_000,
                                        reachedLiveState: false, canReconnectInPlace: true) == .stop)
    }

    /// A PS5 session has no control-channel health to ask after a wake; it
    /// used to be ended on every wake. Video that is arriving again says the
    /// link came through the sleep.
    @Test func videoArrivingAfterAWakeKeepsAPs5Stream() {
        #expect(StreamSession.wakeProbeSaysAlive(receiveIdleMs: 12, budgetMs: 750))
        #expect(!StreamSession.wakeProbeSaysAlive(receiveIdleMs: 900, budgetMs: 750))
        #expect(!StreamSession.wakeProbeSaysAlive(receiveIdleMs: .infinity, budgetMs: 750))
    }

    /// An unreadable consoles file is kept, not saved over: the next
    /// registration used to write a one-console list on top of it, and every
    /// other console's registration key went with it.
    @MainActor
    @Test func anUnreadableConsoleStoreIsMovedAsideNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("consoles.json")
        let precious = Data(#"[{"id":"aabbccddeeff","a field this build does not know":true}]"#.utf8)
        try precious.write(to: file)

        let store = PlayStationStore(directory: dir)
        #expect(store.consoles.isEmpty)
        store.upsert(PlayStationConsole(id: "112233445566", nickname: "New", address: "10.0.0.9",
                                        registKey: Data(repeating: 1, count: 16),
                                        rpKey: Data(repeating: 2, count: 16), target: 1_000_100))

        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("consoles.unreadable-") }
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(try #require(kept.first))) == precious)
        // And the new registration saved normally beside it.
        #expect(PlayStationStore(directory: dir).consoles.map(\.id) == ["112233445566"])
    }
}
