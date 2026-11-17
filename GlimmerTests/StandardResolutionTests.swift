//
//  StandardResolutionTests.swift
//
//  Resolution offers the four standard sizes only - no Match display, HiDPI
//  or Custom. A PC saved on one of those streams the nearest standard size.
//

import Testing
@testable import Glimmer

struct StandardResolutionTests {
    @Test func pickerListsStandardSizesOnly() {
        #expect(ResolutionChoice.all == [.standard(.hd720), .standard(.hd1080), .standard(.qhd1440), .standard(.uhd4K)])
    }
    @Test func nearestByPixelCount() {
        #expect(CommonResolution.nearest(width: 3456, height: 2234) == .uhd4K)
        #expect(CommonResolution.nearest(width: 2560, height: 1600) == .qhd1440)
        #expect(CommonResolution.nearest(width: 1728, height: 1117) == .hd1080)
        #expect(CommonResolution.nearest(width: 1280, height: 720) == .hd720)
    }
    @Test func matchDisplaySettingsBecomeTheNearestStandardSize() {
        var saved = HostStreamSettings.defaults
        saved.qualityPreset = QualityPreset.matchDisplay.rawValue
        let fixed = saved.withStandardResolution(display: (3456, 2234), hidpi: (1728, 1117))
        #expect(fixed.qualityPreset == QualityPreset.custom.rawValue)
        #expect(fixed.customWidth == 3840 && fixed.customHeight == 2160)
    }
    @Test func hidpiSettingsBecomeTheNearestStandardSize() {
        var saved = HostStreamSettings.defaults
        saved.qualityPreset = QualityPreset.hidpi.rawValue
        let fixed = saved.withStandardResolution(display: (3456, 2234), hidpi: (1728, 1117))
        #expect(fixed.customWidth == 1920 && fixed.customHeight == 1080)
    }
    @Test func customSizeSnapsToAStandardOne() {
        var saved = HostStreamSettings.defaults
        saved.qualityPreset = QualityPreset.custom.rawValue
        saved.customWidth = 2400; saved.customHeight = 1350
        let fixed = saved.withStandardResolution(display: (3456, 2234), hidpi: (1728, 1117))
        #expect(fixed.customWidth == 2560 && fixed.customHeight == 1440)
    }
    @Test func standardSizeIsLeftAlone() {
        var saved = HostStreamSettings.defaults
        saved.qualityPreset = QualityPreset.custom.rawValue
        saved.customWidth = 1920; saved.customHeight = 1080; saved.customFPS = 75
        #expect(saved.withStandardResolution(display: (3456, 2234), hidpi: (1728, 1117)) == saved)
    }

    /// A PC saved on a custom frame rate (gone from the menu) streams the
    /// nearest standard rate instead, and keeps it.
    @Test func customFrameRateSnapsToAStandardOne() {
        var saved = HostStreamSettings.defaults
        saved.customFPS = 75
        #expect(saved.withStandardFrameRate().customFPS == 60)
        saved.customFPS = 144
        #expect(saved.withStandardFrameRate() == saved)
    }
}
