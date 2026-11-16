//
//  SettingsLayoutTests.swift
//
//  Servers / General / About only; the old Sunshine and PlayStation tabs open
//  Servers; the bitrate slider's snap points.
//

import CoreGraphics
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
    /// Back to Tailscale's Accounts window: 600 pt wide, 528 tall on Servers.
    @Test func windowIsTailscaleSized() {
        #expect(SettingsMetrics.windowWidth == 600)
        #expect(SettingsTab.computers.windowHeight == CGFloat(528 - 32))
    }
    /// A machine's page fits beside the sidebar: gutter, control and the
    /// bitrate readout ("100 Mbps") inside the detail's margins.
    @Test func machinePageFitsBesideTheSidebar() {
        let page = SettingsMetrics.windowWidth - SettingsMetrics.serversSidebarWidth - 1
        let row = SettingsMetrics.serversPageLeading + SettingsMetrics.serversLabelGutter
            + SettingsMetrics.labelGap + SettingsMetrics.serversControlWidth
            + 10 + 64 + SettingsMetrics.serversPageTrailing
        #expect(row <= page)
        #expect(SettingsMetrics.serversLabelGutter >= 84)  // "Presentation:"
    }
    @Test func bitrateStops() {
        #expect(BitrateSlider.stopsMbps == [5, 10, 15, 20, 30, 40, 50, 75, 100, 150, 200, 300])
        #expect(BitrateSlider.nearestStopIndex(mbps: 100, maxMbps: 100) == 8)
        #expect(BitrateSlider.nearestStopIndex(mbps: 25, maxMbps: 300) == 3)
        #expect(BitrateSlider.nearestStopIndex(mbps: 400, maxMbps: 100) == 8)
    }
}
