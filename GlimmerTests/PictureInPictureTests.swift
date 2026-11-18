//
//  PictureInPictureTests.swift
//
//  Hardware-free coverage for the Picture in Picture decision logic: the
//  present-suppression truth table StreamWindow feeds the decoder, the
//  mirror-source sizing that keeps the 1:1 PiP mirror free of hairline gaps,
//  the default chord's non-collision with the other client-side chords, and
//  the keep-alive that redraws the PiP panel (see `PiPKeepAlive`).
//

import AppKit
import CoreGraphics
import Testing
@testable import Glimmer

struct PictureInPictureTests {

    // MARK: - Present suppression truth table

    private func suppressed(
        backgrounded: Bool, pipActive: Bool = false, pipPending: Bool = false, pipPaused: Bool = false
    ) -> Bool {
        StreamWindow.presentSuppressedState(
            backgrounded: backgrounded, pipActive: pipActive, pipPending: pipPending, pipPaused: pipPaused)
    }

    @Test func visibleWindowIsNeverSuppressed() {
        #expect(suppressed(backgrounded: false) == false)
        #expect(suppressed(backgrounded: false, pipActive: true) == false)
        #expect(suppressed(backgrounded: false, pipPending: true) == false)
    }

    @Test func hiddenWindowWithoutPiPIsSuppressed() {
        // The pre-PiP behaviour: Cmd-Tab away → drain to newest, decode gates.
        #expect(suppressed(backgrounded: true) == true)
    }

    @Test func openingStraightIntoPiPDecodesTheFirstFrames() {
        // Hidden from the start, PiP not up yet: the first frames must decode
        // (they are what starts PiP). Pausing still wins.
        #expect(StreamWindow.presentSuppressedState(backgrounded: true, pipActive: false, pipPending: false,
                                                    pipPaused: false, launchingIntoPiP: true) == false)
        #expect(StreamWindow.presentSuppressedState(backgrounded: true, pipActive: false, pipPending: false,
                                                    pipPaused: true, launchingIntoPiP: true) == true)
    }

    @Test func launchUsesTheLastPiPFrameOnlyWhenItIsStillOnScreen() {
        let screen = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let corner = NSRect(x: 2000, y: 1100, width: 480, height: 270)
        #expect(StreamWindow.validPiPFrame(corner, screens: [screen]) == corner)
        // A display that's gone, a frame half off screen, a degenerate size.
        #expect(StreamWindow.validPiPFrame(NSRect(x: 3000, y: 100, width: 480, height: 270), screens: [screen]) == nil)
        #expect(StreamWindow.validPiPFrame(NSRect(x: 2300, y: 1300, width: 480, height: 270), screens: [screen]) == nil)
        #expect(StreamWindow.validPiPFrame(NSRect(x: 10, y: 10, width: 20, height: 10), screens: [screen]) == nil)
    }

    @Test func hiddenWindowShowingInPiPIsNotSuppressed() {
        #expect(suppressed(backgrounded: true, pipActive: true) == false)
    }

    @Test func hiddenWindowWhilePiPIsStartingIsNotSuppressed() {
        // Entering PiP must not cost a drain + IDR resync for the ~100ms AVKit
        // takes to bring the window up.
        #expect(suppressed(backgrounded: true, pipPending: true) == false)
    }

    @Test func pauseFromPiPControlsSuppressesRegardless() {
        #expect(suppressed(backgrounded: true, pipActive: true, pipPaused: true) == true)
        #expect(suppressed(backgrounded: false, pipActive: true, pipPaused: true) == true)
    }

    // MARK: - Fitting the picture into Apple's PiP window

    @Test func panelScaleFitsTheSourceSizedVideoViewToThePanel() throws {
        // Measured on macOS 27.2.1: a 1600x900 source in a 529x297 panel.
        let t = try #require(PiPPanelFitter.panelScale(video: CGSize(width: 1600, height: 900),
                                                       panel: CGSize(width: 529, height: 297)))
        #expect(abs(t.m11 * 1600 - 529) < 0.001)
        #expect(abs(t.m22 * 900 - 297) < 0.001)
        // Already fitted (Apple fixed it): identity, so nothing changes.
        let same = try #require(PiPPanelFitter.panelScale(video: CGSize(width: 529, height: 297),
                                                          panel: CGSize(width: 529, height: 297)))
        #expect(PiPPanelFitter.approximatelyEqual(same, CATransform3DIdentity))
        #expect(PiPPanelFitter.panelScale(video: .zero, panel: CGSize(width: 10, height: 10)) == nil)
    }

    @Test func containerMappingLandsThePictureExactlyOnItsHost() throws {
        // A picture offset inside a layer that is itself offset in its host
        // (a letterboxed source): every corner must land on the host's.
        let picture = CGRect(x: 0, y: 60, width: 1600, height: 780)
        let layerFrame = CGRect(x: 0, y: -40, width: 1600, height: 900)
        let anchor = CGPoint(x: 0.5, y: 0.5)
        let host = CGSize(width: 1600, height: 900)
        let t = try #require(PiPPanelFitter.containerMapping(picture: picture, layerFrame: layerFrame,
                                                             anchorPoint: anchor, host: host))
        // A sublayer transform pivots on the anchor: p' = (p - pivot) * s + pivot, then the layer's offset.
        func land(_ p: CGPoint) -> CGPoint {
            let pivot = CGPoint(x: anchor.x * layerFrame.width, y: anchor.y * layerFrame.height)
            let x = (p.x - pivot.x) * t.m11 + pivot.x + t.m41 + layerFrame.minX
            let y = (p.y - pivot.y) * t.m22 + pivot.y + t.m42 + layerFrame.minY
            return CGPoint(x: x, y: y)
        }
        let lo = land(CGPoint(x: picture.minX, y: picture.minY))
        let hi = land(CGPoint(x: picture.maxX, y: picture.maxY))
        #expect(abs(lo.x) < 0.001 && abs(lo.y) < 0.001)
        #expect(abs(hi.x - host.width) < 0.001 && abs(hi.y - host.height) < 0.001)
    }

    @Test func returnTargetIsTheWindowsPicture() {
        // A 16:9 stream in a 16:10 full-screen window: letterboxed, centred.
        let r = StreamWindowGeometry.aspectFit(CGSize(width: 1920, height: 1080),
                                               in: CGRect(x: 0, y: 0, width: 1728, height: 1080))
        #expect(r == CGRect(x: 0, y: 54, width: 1728, height: 972))
    }

    @Test func sourceSitsAtTheStreamsResolutionAndStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        // 1080p on a 2x screen: 960x540 points, centred where asked.
        let f = PiPSource.nativeFrame(pixelSize: CGSize(width: 1920, height: 1080), backingScale: 2,
                                      center: CGPoint(x: 1280, y: 720), screen: screen)
        #expect(f == CGRect(x: 800, y: 450, width: 960, height: 540))
        // Centred on a PiP window in the top-right corner: pulled back on screen.
        let corner = PiPSource.nativeFrame(pixelSize: CGSize(width: 1920, height: 1080), backingScale: 2,
                                           center: CGPoint(x: 2400, y: 1300), screen: screen)
        #expect(screen.contains(corner))
        // 4K on a 1x screen is bigger than the screen: shrunk to fit.
        let big = PiPSource.nativeFrame(pixelSize: CGSize(width: 3840, height: 2160), backingScale: 1,
                                        center: CGPoint(x: 1280, y: 720), screen: screen)
        #expect(screen.contains(big) && big.width <= 2560)
    }

    // MARK: - Default chord

    @Test func defaultPiPChordDoesNotCollideWithOtherClientChords() {
        let chords: [HotkeyChord] = [.defaultQuit, .defaultStats, .defaultBookmark, .defaultPiP]
        for (i, a) in chords.enumerated() {
            for b in chords[(i + 1)...] {
                #expect(a != b)
            }
        }
    }

    // MARK: - Recording keep-alive

    /// What matters is that every nudge is a real change in the panel's own
    /// layer tree - a no-op assignment commits nothing, and nothing committed
    /// leaves the picture frozen.
    @MainActor @Test func keepAliveNudgesALayerInsideThePanelAndCleansUp() throws {
        let panelContent = NSView(frame: NSRect(x: 0, y: 0, width: 584, height: 329))
        let keepAlive = PiPKeepAlive(in: panelContent)
        let host = try #require(panelContent.subviews.first)
        #expect(panelContent.subviews.count == 1)
        let dot = try #require(host.layer?.sublayers?.first)
        #expect(dot.bounds.size == CGSize(width: 1, height: 1))

        let start = dot.position
        keepAlive.nudge()
        let moved = dot.position
        #expect(moved != start)
        keepAlive.nudge()
        #expect(dot.position != moved)

        // It sits over the picture's corner: clicks there must still reach PiP.
        #expect(panelContent.hitTest(NSPoint(x: 0.5, y: 0.5)) === panelContent)

        keepAlive.stop()
        #expect(panelContent.subviews.isEmpty)
    }

    @MainActor @Test func keepAliveBoundsTheFreezeToAFrameOrThree() {
        // 60 fps frames are 16.7 ms apart; staying stuck for more than a few
        // of them after the animation is a visible hitch.
        #expect(PiPKeepAlive.interval <= 0.05)
    }

    /// Closing PiP from code plays the × button's own animation through a
    /// private AVKit call. If a macOS update drops or changes it, PiP closes
    /// at once instead - and this test says so.
    @MainActor @Test func theCloseButtonsOwnCloseIsAvailableOnThisMacOS() {
        #expect(StreamPictureInPicture.canCloseAsTheCloseButtonDoes)
    }

    /// The PiP window's pause button is hidden through a private AVKit
    /// setting. If a macOS update drops it the button comes back (pausing is
    /// still refused) - and this test says so.
    @MainActor @Test func thePauseButtonCanBeHiddenOnThisMacOS() {
        #expect(StreamPictureInPicture.canHidePlaybackControls)
    }

    @Test func defaultPiPChordCarriesNoCommandModifier() {
        // No Cmd, so it is intercepted before the sys-keys gate and fires
        // regardless of the "use ⌘ shortcuts inside the game" toggle.
        #expect(HotkeyChord.defaultPiP.cmd == false)
        #expect(HotkeyChord.defaultPiP.displayString == "⌃⌥P")
    }
}

/// Switch PC in Picture in Picture: the old stream's PiP closes and the next
/// stream opens its own (AppModel.switchHost, HostSwitchTests).
@MainActor
struct PictureInPictureSwitchTests {
    @Test func endingTheStreamYourselfDropsAnUncommittedSwitch() {
        let model = AppModel()
        model.pendingHostSwitch = AppModel.PendingHostSwitch(hostID: "ps5-test", inPictureInPicture: true,
                                                             requestedAt: Date())
        StreamWindow.switchingHosts = false   // still waking the PS5
        model.endStream()
        #expect(model.pendingHostSwitch == nil)
    }
}
