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

    /// The app's own settings these tests move (they run inside Shimmer.app,
    /// so UserDefaults.standard is the real app's): put back afterwards.
    private static let touchedKeys = ["glimmer.selectedHostID", "glimmer.streamSettingsMigrated", "qualityPreset",
                                      "customWidth", "customHeight", "customFPS", "bitrateAuto",
                                      "manualBitrateMbps", "customHDR", "quitAppWhenStreamEnds"]

    private static func preservingAppDefaults(_ body: () -> Void) {
        let d = UserDefaults.standard
        let saved = touchedKeys.map { ($0, d.object(forKey: $0)) }
        defer { for (key, value) in saved { d.set(value, forKey: key) } }
        body()
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
        Self.preservingAppDefaults {
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
    }

    @Test func editsPersistPerHost() {
        Self.preservingAppDefaults {
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
    }

    @Test func migrationSeedsExistingHostsOnly() {
        Self.preservingAppDefaults {
            let old = Self.host("hss-old-\(UUID().uuidString)"), new = Self.host("hss-new-\(UUID().uuidString)")
            defer { Self.cleanup(old.id, new.id) }
            let model = AppModel()
            model.customFPS = 90
            model.migrateStreamSettingsToHosts([old], force: true)
            #expect(HostStreamSettings.load(hostID: old.id)?.customFPS == 90)
            model.selectHost(new)   // added after the migration: defaults
            #expect(model.customFPS == HostStreamSettings.defaults.customFPS)
        }
    }

    @Test func streamingAPCSelectsItFirst() {
        Self.preservingAppDefaults {
            let a = Self.host("hss-a-\(UUID().uuidString)"), b = Self.host("hss-b-\(UUID().uuidString)")
            defer { Self.cleanup(a.id, b.id) }
            var sa = HostStreamSettings.defaults; sa.customFPS = 120; sa.save(hostID: a.id)
            var sb = HostStreamSettings.defaults; sb.customFPS = 30; sb.save(hostID: b.id)
            let model = AppModel()
            model.hosts = [a, b]
            model.selectHost(b)
            model.selectForStream(a)
            #expect(model.selectedHost?.id == a.id)
            #expect(model.customFPS == 120)
        }
    }

    @Test func manualBitrateLandsOnASliderStop() {
        Self.preservingAppDefaults {
            let a = Self.host("hss-a-\(UUID().uuidString)")
            defer { Self.cleanup(a.id) }
            let model = AppModel()
            model.selectHost(a)
            for (w, h, fps) in [(1280, 720, 30), (1920, 1080, 60), (2560, 1440, 120), (3840, 2160, 60)] {
                model.qualityPreset = .custom
                model.customWidth = w; model.customHeight = h; model.customFPS = fps
                model.bitrateAuto = true
                model.bitrateAuto = false
                #expect(BitrateSlider.stopsMbps.contains(model.manualBitrateMbps),
                        "\(w)x\(h)@\(fps) -> \(model.manualBitrateMbps) Mbps")
            }
        }
    }

    @Test func quitSettingFollowsStreamingHost() {
        Self.preservingAppDefaults {
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
}
