//
//  SettingsLayoutTests.swift
//
//  Servers / General / About only; the old Sunshine and PlayStation tabs open
//  Servers; the bitrate slider's snap points.
//

import Testing
@testable import Glimmer

struct SettingsLayoutTests {
    @Test func onlyThreeTabs() {
        #expect(SettingsTab.allCases.map(\.rawValue) == ["computers", "general", "about"])
    }
    @Test func removedTabsOpenServers() {
        #expect(SettingsTab(persisted: "stream") == .computers)
        #expect(SettingsTab(persisted: "playStation") == .computers)
        #expect(SettingsTab(persisted: "general") == .general)
    }
    @Test func bitrateStops() {
        #expect(BitrateSlider.stopsMbps == [5, 10, 15, 20, 30, 40, 50, 75, 100, 150, 200, 300])
        #expect(BitrateSlider.nearestStopIndex(mbps: 100, maxMbps: 100) == 8)
        #expect(BitrateSlider.nearestStopIndex(mbps: 25, maxMbps: 300) == 3)
        #expect(BitrateSlider.nearestStopIndex(mbps: 400, maxMbps: 100) == 8)
    }
}
