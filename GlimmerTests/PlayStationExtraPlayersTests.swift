//
//  PlayStationExtraPlayersTests.swift
//
//  Players 2-4 on a PS5 are console users seated by PSN account ID: the
//  stored base64 form (8 bytes, little-endian, as Remote Play registration
//  uses) must decode to the number ctrl 0x68 sends.
//

import Foundation
import Testing
@testable import Glimmer

struct PlayStationExtraPlayersTests {
    @Test func base64AccountIDIsLittleEndian() {
        #expect(PlayStationSettings.accountID(base64: "AQAAAAAAAAA=") == 1)
        #expect(PlayStationSettings.accountID(base64: "AAAAAAAAAIA=") == 1 << 63)
        #expect(PlayStationSettings.accountID(base64: "AQID") == nil)     // not 8 bytes
        #expect(PlayStationSettings.accountID(base64: "not base64") == nil)
    }

    @Test func extraPlayersComeFromDefaultsInOrder() {
        let d = UserDefaults.standard
        let saved = d.object(forKey: "PS5.extraPlayers")
        defer { d.set(saved, forKey: "PS5.extraPlayers") }
        d.set(["AgAAAAAAAAA=", "bogus", "AwAAAAAAAAA="], forKey: "PS5.extraPlayers")
        #expect(PlayStationSettings.extraPlayerAccounts == [2, 3])
    }
}
