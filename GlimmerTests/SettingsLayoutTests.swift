//
//  SettingsLayoutTests.swift
//
//  Servers / General / Controller / About; the old Sunshine and PlayStation tabs open
//  Servers; the bitrate slider's snap points.
//

import CoreGraphics
import Testing
@testable import Glimmer

struct SettingsLayoutTests {
    @Test func fourTabs() {
        #expect(SettingsTab.allCases.map(\.rawValue) == ["computers", "general", "controller", "about"])
    }
    @Test func removedTabsOpenServers() {
        #expect(SettingsTab(persisted: "stream") == .computers)
        #expect(SettingsTab(persisted: "playStation") == .computers)
        #expect(SettingsTab(persisted: "general") == .general)
    }
    /// Back to Tailscale's Accounts window: 600 pt wide, 528 tall on Servers.
    @Test func windowIsTailscaleSized() {
        #expect(SettingsMetrics.windowWidth == 600)
        #expect(SettingsTab.computers.windowHeight == CGFloat(528 - 32))
    }
    @Test func bitrateStops() {
        #expect(BitrateSlider.stopsMbps == [5, 10, 15, 20, 30, 40, 50, 75, 100, 150, 200, 300])
        #expect(BitrateSlider.nearestStopIndex(mbps: 100, maxMbps: 100) == 8)
        #expect(BitrateSlider.nearestStopIndex(mbps: 25, maxMbps: 300) == 3)
        #expect(BitrateSlider.nearestStopIndex(mbps: 400, maxMbps: 100) == 8)
    }

    /// Picture in Picture on switching away is off for a fresh install (its
    /// row left General).
    @MainActor @Test func switchingAwayDoesNotStartPictureInPicture() {
        #expect(AppModel.defaultAutoPictureInPicture == false)
    }
}

/// What left Settings stays reachable from `shimmerctl set` (an agent turns
/// recording on to diagnose a stream), and `shimmerctl state` shows it.
@MainActor
struct AgentSettingsTests {
    private static let keys = ["telemetryEnabled", "showStreamStats", "autoPictureInPicture",
                               KeepAwakePolicy.defaultsKey]

    private static func preservingDefaults(_ body: () -> Void) {
        let d = UserDefaults.standard
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        defer { for (key, value) in saved { d.set(value, forKey: key) } }
        body()
    }

    @Test func recordingTurnsOnAndOff() {
        Self.preservingDefaults {
            let model = AppModel()
            #expect(AgentControl.applySetting("recording", "on", to: model).hasPrefix("recording on"))
            #expect(model.telemetryEnabled)
            _ = AgentControl.applySetting("recording", "off", to: model)
            #expect(!model.telemetryEnabled)
        }
    }

    @Test func everyHiddenSettingIsReachable() {
        Self.preservingDefaults {
            let model = AppModel()
            _ = AgentControl.applySetting("stats", "on", to: model)
            _ = AgentControl.applySetting("auto-pip", "on", to: model)
            _ = AgentControl.applySetting("keep-awake", "on", to: model)
            #expect(model.showStreamStats)
            #expect(model.autoPictureInPicture)
            #expect(model.keepAwakePolicy == .always)
            let settings = AgentControl.settingsState(model)
            #expect(settings["stats"] as? Bool == true)
            #expect(settings["auto-pip"] as? Bool == true)
            #expect(settings["keep-awake"] as? Bool == true)
            #expect((settings["recordings_folder"] as? String)?.hasSuffix("Library/Logs/Shimmer") == true)
        }
    }

    @Test func unknownSettingOrValueChangesNothing() {
        Self.preservingDefaults {
            let model = AppModel()
            let before = model.telemetryEnabled
            #expect(AgentControl.applySetting("volume", "on", to: model).contains("known:"))
            #expect(AgentControl.applySetting("recording", "maybe", to: model).contains("on or off"))
            #expect(model.telemetryEnabled == before)
        }
    }
}
