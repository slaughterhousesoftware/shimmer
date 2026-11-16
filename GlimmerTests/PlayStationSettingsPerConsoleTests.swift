//
//  PlayStationSettingsPerConsoleTests.swift
//
//  Each PS5 keeps its own settings; consoles registered before per-console
//  settings keep what they had.
//

import Foundation
import Testing
@testable import Glimmer

@MainActor
struct PlayStationSettingsPerConsoleTests {
    private func suite() throws -> (UserDefaults, String) {
        let name = "ps5s-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func consolesKeepSeparateSettings() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let a = PlayStationSettings(hostID: "ps5-a", defaults: defaults)
        a.fps = 30
        let b = PlayStationSettings(hostID: "ps5-b", defaults: defaults)
        #expect(b.fps == 60)
        #expect(PlayStationSettings(hostID: "ps5-a", defaults: defaults).fps == 30)
    }

    @Test func existingConsoleKeepsGlobalValues() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(30, forKey: "PS5.fps")
        defaults.set(false, forKey: "PS5.hevc")
        PlayStationSettings.migrateGlobalToConsoles(["ps5-old"], defaults: defaults)
        let old = PlayStationSettings(hostID: "ps5-old", defaults: defaults)
        #expect(old.fps == 30)
        #expect(old.hevc == false)
    }

    @Test func newConsoleAfterMigrationGetsDefaults() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(30, forKey: "PS5.fps")
        PlayStationSettings.migrateGlobalToConsoles(["ps5-old"], defaults: defaults)
        PlayStationSettings.migrateGlobalToConsoles(["ps5-old", "ps5-new"], defaults: defaults)
        #expect(PlayStationSettings(hostID: "ps5-new", defaults: defaults).fps == 60)
    }
}
