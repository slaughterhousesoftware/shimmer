//
//  HostStreamSettingsTests.swift
//
//  Each PC keeps its own stream settings (resolution, frame rate, bitrate,
//  HDR, quit-on-end): selecting a PC loads its own, edits save to it.
//

import Foundation
import Testing
@testable import Glimmer

@MainActor
@Suite(.serialized)
struct HostStreamSettingsTests {
    private static func host(_ id: String) -> Glimmer.Host {
        Glimmer.Host(id: id, name: id, customName: nil, localAddress: nil, manualAddress: nil, apps: [],
             lastConnected: nil, serverCertPEM: nil, appVersion: nil, gfeVersion: nil, macAddress: nil)
    }

    private static func cleanup(_ ids: String...) {
        for id in ids { UserDefaults.standard.removeObject(forKey: HostStreamSettings.storageKey(for: id)) }
    }

    @Test func roundTripsThroughDefaults() throws {
        let suite = "hss-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var s = HostStreamSettings.defaults
        s.customFPS = 120
        s.quitAppWhenStreamEnds = true
        s.save(hostID: "pc", defaults: defaults)
        #expect(HostStreamSettings.load(hostID: "pc", defaults: defaults) == s)
        #expect(HostStreamSettings.load(hostID: "other", defaults: defaults) == nil)
    }

    @Test func selectingAHostLoadsItsSettings() {
        let a = Self.host("hss-a-\(UUID().uuidString)"), b = Self.host("hss-b-\(UUID().uuidString)")
        defer { Self.cleanup(a.id, b.id) }
        var sa = HostStreamSettings.defaults; sa.customFPS = 120; sa.save(hostID: a.id)
        var sb = HostStreamSettings.defaults; sb.customFPS = 60; sb.save(hostID: b.id)
        let model = AppModel()
        model.selectHost(a)
        #expect(model.customFPS == 120)
        model.selectHost(b)
        #expect(model.customFPS == 60)
    }

    @Test func editsPersistPerHost() {
        let a = Self.host("hss-a-\(UUID().uuidString)"), b = Self.host("hss-b-\(UUID().uuidString)")
        defer { Self.cleanup(a.id, b.id) }
        HostStreamSettings.defaults.save(hostID: a.id)
        HostStreamSettings.defaults.save(hostID: b.id)
        let model = AppModel()
        model.selectHost(a)
        model.customFPS = 144
        model.customHDR = false
        model.selectHost(b)
        #expect(model.customFPS == HostStreamSettings.defaults.customFPS)
        model.selectHost(a)
        #expect(model.customFPS == 144)
        #expect(model.customHDR == false)
    }

    @Test func migrationSeedsExistingHostsOnly() {
        let old = Self.host("hss-old-\(UUID().uuidString)"), new = Self.host("hss-new-\(UUID().uuidString)")
        defer { Self.cleanup(old.id, new.id) }
        let model = AppModel()
        model.customFPS = 90
        model.migrateStreamSettingsToHosts([old], force: true)
        #expect(HostStreamSettings.load(hostID: old.id)?.customFPS == 90)
        model.selectHost(new)   // added after the migration: defaults
        #expect(model.customFPS == HostStreamSettings.defaults.customFPS)
    }

    @Test func quitSettingFollowsStreamingHost() {
        let a = Self.host("hss-a-\(UUID().uuidString)"), b = Self.host("hss-b-\(UUID().uuidString)")
        defer { Self.cleanup(a.id, b.id) }
        var sa = HostStreamSettings.defaults; sa.quitAppWhenStreamEnds = true; sa.save(hostID: a.id)
        HostStreamSettings.defaults.save(hostID: b.id)
        let model = AppModel()
        model.selectHost(b)
        #expect(model.streamSettings(for: a.id).quitAppWhenStreamEnds == true)
        #expect(model.streamSettings(for: b.id).quitAppWhenStreamEnds == false)
    }
}
