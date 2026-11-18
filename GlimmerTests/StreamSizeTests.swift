//
//  StreamSizeTests.swift
//
//  The refresh cap at the display, the shared size clamps, and the window
//  geometry (pixel-mapped opening size, fit-to-screen, aspect conformance of
//  a restored frame). All pure - no AppModel, screen, or window involved.
//

import CoreGraphics
import Testing
@testable import Glimmer

struct StreamSizeTests {

    // MARK: Refresh cap

    @Test func windowedRefreshIsCappedAtTheDisplay() {
        // A 60 Hz panel can't show 120 - asking would only drop frames.
        #expect(StreamRefresh.capped(customFPS: 120, displayMaxHz: 60) == 60)
        #expect(StreamRefresh.capped(customFPS: 120, displayMaxHz: 144) == 120)
        #expect(StreamRefresh.capped(customFPS: 60, displayMaxHz: 120) == 60)
    }

    @Test func windowedRefreshIsClampedThenCapped() {
        #expect(StreamRefresh.capped(customFPS: 5, displayMaxHz: 120) == 30)
        #expect(StreamRefresh.capped(customFPS: 1000, displayMaxHz: 240) == 240)
        #expect(StreamRefresh.capped(customFPS: 1000, displayMaxHz: 120) == 120)
    }

    @Test func unknownDisplayRefreshFallsBackTo60() {
        #expect(StreamRefresh.capped(customFPS: 120, displayMaxHz: 0) == 60)
        #expect(StreamRefresh.capped(customFPS: 120, displayMaxHz: -1) == 60)
        #expect(StreamRefresh.capped(customFPS: 30, displayMaxHz: 0) == 30)
    }

    // MARK: Shared size clamps

    @Test func sizeClampsMatchTheCustomPresetBounds() {
        #expect(StreamSizeBounds.clampWidth(99_999) == 7680)
        #expect(StreamSizeBounds.clampWidth(100) == 640)
        #expect(StreamSizeBounds.clampWidth(2560) == 2560)
        #expect(StreamSizeBounds.clampHeight(99_999) == 4320)
        #expect(StreamSizeBounds.clampHeight(10) == 480)
        #expect(StreamSizeBounds.clampHeight(1600) == 1600)
        #expect(StreamSizeBounds.clampFPS(1000) == 240)
        #expect(StreamSizeBounds.clampFPS(5) == 30)
        #expect(StreamSizeBounds.clampFPS(144) == 144)
    }

    // MARK: Window geometry

    @Test func pixelMappedSizeDividesByTheBackingScale() {
        #expect(StreamWindowGeometry.pixelMappedContentSize(pixelWidth: 1920, pixelHeight: 1080, backingScaleFactor: 2)
            == CGSize(width: 960, height: 540))
        #expect(StreamWindowGeometry.pixelMappedContentSize(pixelWidth: 1920, pixelHeight: 1080, backingScaleFactor: 1)
            == CGSize(width: 1920, height: 1080))
        // A screen mid-reconfigure reports 0 - treat as 1x, never divide by it.
        #expect(StreamWindowGeometry.pixelMappedContentSize(pixelWidth: 1280, pixelHeight: 720, backingScaleFactor: 0)
            == CGSize(width: 1280, height: 720))
    }

    @Test func fitPreservesAspectAndNeverScalesUp() {
        let fourK = CGSize(width: 3840, height: 2160)
        #expect(StreamWindowGeometry.fitted(fourK, within: CGSize(width: 1920, height: 1200))
            == CGSize(width: 1920, height: 1080))
        // Height-bound: a tall available area limits by height.
        #expect(StreamWindowGeometry.fitted(fourK, within: CGSize(width: 4000, height: 1080))
            == CGSize(width: 1920, height: 1080))
        // Already fits: unchanged, never enlarged.
        let small = CGSize(width: 960, height: 540)
        #expect(StreamWindowGeometry.fitted(small, within: CGSize(width: 1920, height: 1080)) == small)
    }


    @Test func minimumSizeSitsOnTheAspectLine() {
        #expect(StreamWindowGeometry.minimumContentSize(aspect: CGSize(width: 16, height: 9))
            == CGSize(width: 640, height: 360))
        #expect(StreamWindowGeometry.minimumContentSize(aspect: CGSize(width: 16, height: 10))
            == CGSize(width: 640, height: 400))
        // A degenerate aspect falls back to 16:9 rather than a zero height.
        #expect(StreamWindowGeometry.minimumContentSize(aspect: .zero) == CGSize(width: 640, height: 360))
    }
}
