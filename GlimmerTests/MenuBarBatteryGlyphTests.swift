//
//  MenuBarBatteryGlyphTests.swift
//
//  The controller battery shown in the menu-bar label. The glyph is a baked
//  asset per level (see MenuBarBatteryGlyph for why it can't be composed at
//  runtime), so the thing worth holding is the mapping: every reading has to
//  name an asset that is ACTUALLY IN THE CATALOG. A name with nothing behind it
//  draws nothing in the menu bar - no error, no fallback, just an icon that
//  quietly isn't there.
//

import AppKit
import GameController
import Testing
@testable import Glimmer

struct MenuBarBatteryGlyphTests {

    // MARK: Every reading resolves to real art

    /// The load-bearing test. Sweeps well past the legal range because both
    /// battery sources can report outside it.
    @Test func everyReadingNamesAnAssetThatExists() {
        for percent in stride(from: -60, through: 160, by: 1) {
            for charging in [false, true] {
                let name = MenuBarBatteryGlyph.assetName(forPercent: percent, charging: charging)
                #expect(NSImage(named: name) != nil,
                        "\(percent)% charging=\(charging) -> \(name), which is not in the catalog")
            }
        }
    }

    /// Every pad Steam has a glyph for has its full set: each level, charging,
    /// and the plain glyph for a pad without a battery reading.
    @Test func everyControllerKindHasItsArt() {
        for kind in MenuBarBatteryGlyph.kinds {
            for percent in stride(from: 0, through: 100, by: MenuBarBatteryGlyph.step) {
                for charging in [false, true] {
                    let name = MenuBarBatteryGlyph.assetName(forPercent: percent, charging: charging, kind: kind)
                    #expect(NSImage(named: name)?.isTemplate == true, "\(name) missing or not a template")
                }
            }
            let plain = MenuBarBatteryGlyph.glyphName(kind: kind)
            #expect(NSImage(named: plain)?.isTemplate == true, "\(plain) missing or not a template")
        }
        // An unknown kind falls back to the generic pad rather than drawing nothing.
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 50, charging: false, kind: "nope")
                == "ControllerBattery-generic-50")
        #expect(MenuBarBatteryGlyph.glyphName(kind: "nope") == "ControllerGlyph-generic")
    }

    /// GameController's names map to the glyph Steam draws for that pad.
    @Test func controllersMapToSteamsGlyphs() {
        let kind = AppModel.steamControllerKind
        #expect(kind(GCProductCategoryDualSense, "DualSense Wireless Controller") == "ps5")
        #expect(kind(GCProductCategoryDualShock4, "DUALSHOCK 4 Wireless Controller") == "ps4")
        #expect(kind(GCProductCategoryXboxOne, "Xbox Wireless Controller") == "xbox")
        #expect(kind("Switch Pro Controller", "Pro Controller") == "switchpro")
        #expect(kind("Nintendo Switch Joy-Con (L/R)", "Joy-Con (L/R)") == "switchpro")
        #expect(kind(GCProductCategoryHID, "8BitDo Ultimate 2C Wireless") == "8bitdo_ultimate")
        #expect(kind(GCProductCategoryHID, "8BitDo SN30 Pro") == "8bitdo_sn30")
        #expect(kind(GCProductCategoryHID, "8BitDo Pro 2") == "8bitdo_pro")
        #expect(kind(GCProductCategoryHID, "HORIPAD") == "hori")
        #expect(kind(GCProductCategoryHID, "Steam Controller") == "triton")
        #expect(kind(GCProductCategoryMFi, "SteelSeries Nimbus+") == "generic")
        #expect(kind(GCProductCategoryHID, nil) == "generic")
    }

    /// And the art is template art, or the menu bar can't tint it for a dark bar.
    @Test func theArtIsATemplate() {
        for percent in [0, 50, 100] {
            for charging in [false, true] {
                let name = MenuBarBatteryGlyph.assetName(forPercent: percent, charging: charging)
                #expect(NSImage(named: name)?.isTemplate == true, "\(name) is not a template")
            }
        }
    }

    /// Charging is a different asset, not the same one - the bolt has to be
    /// baked in, since nothing can be overlaid onto it later. And it is ONE
    /// asset: the bolt stands in for the level while the pad is plugged in.
    @Test func chargingSelectsOneDifferentAsset() {
        for percent in [0, 30, 70, 100] {
            #expect(MenuBarBatteryGlyph.assetName(forPercent: percent, charging: true)
                    != MenuBarBatteryGlyph.assetName(forPercent: percent, charging: false))
            #expect(MenuBarBatteryGlyph.assetName(forPercent: percent, charging: true)
                    == "ControllerBattery-ps5-Charging")
        }
    }

    // MARK: The rounding

    @Test func exactLevelsMapToThemselves() {
        for level in stride(from: 0, through: 100, by: MenuBarBatteryGlyph.step) {
            #expect(MenuBarBatteryGlyph.assetName(forPercent: level, charging: false)
                    == "ControllerBattery-ps5-\(level)")
        }
    }

    @Test func readingsRoundToTheNearestLevel() {
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 4, charging: false) == "ControllerBattery-ps5-0")
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 5, charging: false) == "ControllerBattery-ps5-10")
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 74, charging: false) == "ControllerBattery-ps5-70")
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 75, charging: false) == "ControllerBattery-ps5-80")
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 96, charging: true)
                == "ControllerBattery-ps5-Charging")
    }

    @Test func outOfRangeReadingsClampRatherThanWrap() {
        #expect(MenuBarBatteryGlyph.assetName(forPercent: -90, charging: false) == "ControllerBattery-ps5-0")
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 900, charging: false) == "ControllerBattery-ps5-100")
    }

    /// A dying pad must never be drawn fuller than it is - that's the one
    /// direction of error that matters.
    @Test func theGlyphNeverOverstatesByMoreThanHalfAStep() {
        for percent in 0...100 {
            let shown = Int(MenuBarBatteryGlyph.assetName(forPercent: percent, charging: false)
                .replacingOccurrences(of: "ControllerBattery-ps5-", with: "")) ?? -1
            #expect(shown - percent <= MenuBarBatteryGlyph.step / 2, "\(percent)% shown as \(shown)%")
        }
    }

    @Test func theMappingIsMonotonic() {
        let shown = (0...100).map { percent -> Int in
            Int(MenuBarBatteryGlyph.assetName(forPercent: percent, charging: false)
                .replacingOccurrences(of: "ControllerBattery-ps5-", with: "")) ?? -1
        }
        #expect(shown == shown.sorted())
    }
}

struct MenuBarVisibilityTests {
    @Test func hidingTheMenuBarAlwaysKeepsTheAppInTheDock() {
        for mainOpen in [false, true] {
            for streaming in [false, true] {
                #expect(AppDelegate.activationPolicy(mainOpen: mainOpen, streaming: streaming,
                                                     menuBarVisible: false) == .regular)
            }
        }
    }

    @Test func menuBarOnlyModeStillKeepsLiveStreamsAndWindowsInTheDock() {
        #expect(AppDelegate.activationPolicy(mainOpen: false, streaming: false,
                                             menuBarVisible: true) == .accessory)
        #expect(AppDelegate.activationPolicy(mainOpen: true, streaming: false,
                                             menuBarVisible: true) == .regular)
        #expect(AppDelegate.activationPolicy(mainOpen: false, streaming: true,
                                             menuBarVisible: true) == .regular)
    }

    @Test func aStreamOnlyInPictureInPictureRunsHeadless() {
        // No stream window to return to: out of the Dock, so the status-item
        // menu opens over another app's full screen (macOS 27.2).
        #expect(AppDelegate.activationPolicy(mainOpen: false, streaming: true, menuBarVisible: true,
                                             streamOnlyInPiP: true) == .accessory)
        // The main window open, or no menu bar icon: the Dock stays.
        #expect(AppDelegate.activationPolicy(mainOpen: true, streaming: true, menuBarVisible: true,
                                             streamOnlyInPiP: true) == .regular)
        #expect(AppDelegate.activationPolicy(mainOpen: false, streaming: true, menuBarVisible: false,
                                             streamOnlyInPiP: true) == .regular)
    }

    @Test func anotherAppsFullScreenTakesShimmerOutOfTheDock() {
        // Over another app's full screen a regular app's menu bar menu never
        // shows (macOS 27.2), so even with windows open Shimmer leaves the Dock.
        #expect(AppDelegate.activationPolicy(mainOpen: true, streaming: true, menuBarVisible: true,
                                             otherAppFullScreen: true) == .accessory)
        // ...unless there is no menu bar icon: then the Dock is the only way in.
        #expect(AppDelegate.activationPolicy(mainOpen: true, streaming: true, menuBarVisible: false,
                                             otherAppFullScreen: true) == .regular)
    }

    /// The old "Show status in the menu bar" switch is gone; a Mac that had
    /// it off forgets that and shows the menu bar item again.
    @Test func aMacThatHidTheMenuBarItemGetsItBack() throws {
        let name = "shimmer-menu-bar-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: MenuBarPreferences.retiredVisibilityKey)
        MenuBarPreferences.forgetRetiredSwitch(in: defaults)
        #expect(defaults.object(forKey: MenuBarPreferences.retiredVisibilityKey) == nil)
    }

    /// Nothing to show: no menu bar icon at all (Shimmer has no icon of its
    /// own there), and the Dock is the way in.
    @Test func idleShowsNoIconAndKeepsTheDock() {
        let idle = MenuBarPresentation(warning: false, controller: nil, appGlyph: nil)
        #expect(idle == nil)
        #expect(AppDelegate.activationPolicy(mainOpen: false, streaming: false,
                                             menuBarVisible: idle != nil) == .regular)
    }

    /// Loading with nothing else to show still gets the spinner.
    @Test func loadingWithNothingElseShowsTheSpinnerAlone() {
        let loading = MenuBarPresentation(warning: false, busy: true, controller: nil, appGlyph: nil)
        #expect(loading?.spinning == true)
        #expect(loading?.glyph == .asset(MenuBarSpinner.frameName(0)))
    }

    @Test @MainActor func aSelectedPlayStationShowsItsMarkWhileIdle() {
        let model = AppModel()
        model.selectedHost = Host(id: "ps5-test", name: "PS5", customName: nil,
                                  localAddress: nil, manualAddress: nil, apps: [.playStationHome],
                                  lastConnected: nil, serverCertPEM: nil, appVersion: nil,
                                  gfeVersion: nil, macAddress: nil)
        model.isStreaming = false
        let mark = LibraryApp.playStationHome.glyph
        #expect(model.menuBarPresentation?.glyph == mark || model.menuBarControllerKind != nil)
    }

    @Test func steamStatusReturnsAndDisappearsWithoutAFallback() {
        let steam = MenuBarPresentation(warning: false, controller: nil,
                                        appGlyph: .asset("SteamGlyph"))
        #expect(steam?.glyph == .asset("SteamGlyph"))
        #expect(steam?.title == "")
        #expect(steam?.assetHeight == 15)
        #expect(AppDelegate.activationPolicy(mainOpen: false, streaming: false,
                                             menuBarVisible: steam != nil) == .accessory)
        let ended = MenuBarPresentation(warning: false, controller: nil, appGlyph: nil)
        #expect(ended == nil)
    }

    /// Connecting, switching PCs, waking a PS5: a spinner, over the pad and
    /// the app - but a warning still wins.
    @Test func busyShowsTheSpinner() {
        let busy = MenuBarPresentation(warning: false, busy: true, controller: ("xbox", (75, false)),
                                       appGlyph: .asset("SteamGlyph"))
        #expect(busy?.spinning == true)
        let warning = MenuBarPresentation(warning: true, busy: true, controller: nil, appGlyph: nil)
        #expect(warning?.spinning == false)
        #expect(warning?.glyph == .symbol("exclamationmark.triangle.fill"))
        let calm = MenuBarPresentation(warning: false, controller: ("xbox", (75, false)), appGlyph: nil)
        #expect(calm?.spinning == false)
    }

    @Test @MainActor func aSwitchOrAConnectIsBusy() {
        let model = AppModel()
        #expect(!model.menuBarBusy)
        model.streamPhase = .connecting(stage: "Connecting")
        #expect(model.menuBarBusy)
        model.streamPhase = .streaming
        #expect(!model.menuBarBusy)
        model.pendingHostSwitch = .init(hostID: "pc", inPictureInPicture: true, requestedAt: Date())
        #expect(model.menuBarBusy)
    }

    @Test func warningsStillTakePrecedenceOverControllerAndAppStatus() {
        let warning = MenuBarPresentation(warning: true, controller: ("xbox", (75, false)),
                                          appGlyph: .asset("SteamGlyph"))
        #expect(warning?.glyph == .symbol("exclamationmark.triangle.fill"))
        #expect(warning?.title == "")
    }

    @Test func controllerStatusShowsThatPadsGlyphAndBattery() {
        let xbox = MenuBarPresentation(warning: false, controller: ("xbox", (75, false)),
                                       appGlyph: .asset("SteamGlyph"))
        #expect(xbox?.glyph == .asset("ControllerBattery-xbox-80"))
        #expect(xbox?.title == "")
        let charging = MenuBarPresentation(warning: false, controller: ("ps5", (75, true)),
                                           appGlyph: .asset("SteamGlyph"))
        #expect(charging?.glyph == .asset("ControllerBattery-ps5-Charging"))
        // A pad with no battery reading still names itself, without a battery.
        let noBattery = MenuBarPresentation(warning: false, controller: ("switchpro", nil),
                                            appGlyph: .asset("SteamGlyph"))
        #expect(noBattery?.glyph == .asset("ControllerGlyph-switchpro"))
    }
}

/// The approved pyramid spinner (design variant 06, 1.20 s motion).
struct MenuBarSpinnerTests {
    @Test func oneTurnIsSeventyTwoFramesAtSixtyFramesASecond() {
        #expect(MenuBarSpinner.frameIndex(elapsed: 0) == 0)
        #expect(MenuBarSpinner.frameIndex(elapsed: 1.0 / 60) == 1)
        #expect(MenuBarSpinner.frameIndex(elapsed: 1.0) == 60)
        #expect(MenuBarSpinner.frameIndex(elapsed: 1.199) == 71)
        // Every 1.20 s it starts the next turn.
        #expect(MenuBarSpinner.frameIndex(elapsed: 1.2) == 0)
        #expect(MenuBarSpinner.frameIndex(elapsed: 3.6 + 0.5) == 30)
        #expect(MenuBarSpinner.frameIndex(elapsed: -1) == 0)
    }

    /// Stream from the menu bar first asks the PC what it runs; a PC that
    /// doesn't answer takes ~8 s over it. That is loading too.
    @MainActor @Test func askingThePCBeforeAStreamCountsAsLoading() {
        let model = AppModel()
        #expect(!model.menuBarBusy)
        model.streamCheckHostID = "tower"
        #expect(model.menuBarBusy)
        #expect(model.menuBarPresentation?.spinning == true)
        model.streamCheckHostID = nil
        #expect(!model.menuBarBusy)
    }

    /// Wake & Connect waiting for the woken PC to answer is loading too.
    @MainActor @Test func wakeAndConnectWaitingForThePCCountsAsLoading() {
        let model = AppModel()
        model.powerWaitHostID = "tower"
        #expect(model.menuBarBusy)
        model.powerWaitHostID = nil
        #expect(!model.menuBarBusy)
    }

    /// Cancelling during that check stops it: the spinner ends and nothing
    /// starts afterwards.
    @MainActor @Test func cancellingDuringTheCheckStopsIt() {
        let model = AppModel()
        model.streamCheckHostID = "tower"
        model.streamCheckToken = UUID()
        model.cancelConnect()
        #expect(model.streamCheckHostID == nil)
        #expect(model.streamCheckToken == nil)
        #expect(!model.menuBarBusy)
        model.streamCheckHostID = "tower"
        model.endStream()
        #expect(!model.menuBarBusy)
        #expect(!model.cancelStreamCheck())
    }

    @MainActor @Test func everyFrameShipsAsATemplateAtTheApprovedSize() {
        #expect(MenuBarSpinner.frames.count == 72)
        for index in 0..<72 {
            let image = NSImage(named: MenuBarSpinner.frameName(index))
            #expect(image != nil, "frame \(index) missing from the asset catalog")
            #expect(image?.size == NSSize(width: 24, height: 18))
            #expect(MenuBarSpinner.frames[index].isTemplate)
        }
    }
}

/// The Servers rows: Settings' avatars, in colour only for the one in use,
/// and a highlight that leaves a row when the pointer does.
@MainActor
struct MenuServerRowTests {
    private func playStation() -> Glimmer.Host {
        Glimmer.Host(id: "ps5-row-test", name: "PS5", customName: nil, localAddress: nil, manualAddress: nil,
             apps: [.playStationHome], lastConnected: nil, serverCertPEM: nil, appVersion: nil,
             gfeVersion: nil, macAddress: nil)
    }

    /// The image drawn into a 2x bitmap - a Retina menu's.
    private func bitmap(_ image: NSImage) -> NSBitmapImageRep {
        let side = Int(image.size.width * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func rgb(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let c = rep.colorAt(x: x, y: y)!
        return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255),
                Int(c.alphaComponent * 255))
    }

    @Test func theServerInUseIsInItsLogosColourTheOthersGrey() {
        let light = NSAppearance(named: .aqua)!
        let current = bitmap(MenuHostMark.image(for: playStation(), look: .current, appearance: light))
        let off = bitmap(MenuHostMark.image(for: playStation(), look: .off, appearance: light))
        // In use: the logo's own colours, PlayStation blue (0x0070D1).
        let tint = rgb(current, current.pixelsWide / 10, current.pixelsHigh / 2)
        #expect(tint.b > 180 && tint.r < 40)
        // Off: a faint grey disc, no hue.
        let grey = rgb(off, off.pixelsWide / 10, off.pixelsHigh / 2)
        #expect(abs(grey.r - grey.b) < 12 && grey.a < 40)
    }

    @Test(arguments: [MenuHostMark.Look.current, .off])
    func thePlayStationMarkIsCentredSidewaysAndLiftedALittle(look: MenuHostMark.Look) {
        let rep = bitmap(MenuHostMark.image(for: playStation(), look: look, appearance: NSAppearance(named: .aqua)!))
        let disc = rgb(rep, rep.pixelsWide / 10, rep.pixelsHigh / 2)
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let p = rgb(rep, x, y)
                // Half-strength ink or more, the way the mark is measured.
                // (Off, the disc is 8% black and the ink 50%: by alpha.)
                let inked = look == .off ? p.a > 80
                    : p.a > 200 && abs(p.r - disc.r) + abs(p.g - disc.g) + abs(p.b - disc.b) > 120
                guard inked else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        // In points, y down.
        let centre = Double(rep.pixelsWide) / 2
        let boxX = (Double(minX + maxX + 1) / 2 - centre) / 2, boxY = (Double(minY + maxY + 1) / 2 - centre) / 2
        // Sideways: on the centre, to the pixel.
        #expect(abs(boxX) <= 0.25)
        // Up by its weight's offset, 6.5% of its ~12 pt height (~0.8 pt).
        #expect(boxY < -0.4 && boxY > -1.3)
        // About half the disc across (Focus: 13 pt in 26).
        let width = Double(maxX - minX + 1) / 2
        #expect(width > 11 && width < 17)
    }

    private func bazzite() -> Glimmer.Host {
        Glimmer.Host(id: "bazzite-row-test", name: "bazzite", customName: nil, localAddress: nil,
                     manualAddress: nil, apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil,
                     gfeVersion: nil, macAddress: nil)
    }

    /// Bazzite's logo is a disc with its mark: in use it is that logo as it
    /// is; off, the same mark at the same size and place, in grey.
    @Test func bazziteKeepsItsOwnLogo() {
        let light = NSAppearance(named: .aqua)!
        let current = bitmap(MenuHostMark.image(for: bazzite(), look: .current, appearance: light))
        // The logo's gradient, blue at the top left to purple.
        let rim = rgb(current, current.pixelsWide / 4, current.pixelsHigh * 3 / 4)
        #expect(rim.b > 150 && rim.g < 100)

        let off = bitmap(MenuHostMark.image(for: bazzite(), look: .off, appearance: light))
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<off.pixelsHigh {
            for x in 0..<off.pixelsWide where rgb(off, x, y).a > 80 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        // The press kit's mark: 68% of the disc (342 of 500), on its centre.
        let width = Double(maxX - minX + 1) / 2
        #expect(width > 16.5 && width < 19)
        let centre = Double(off.pixelsWide) / 2
        #expect(abs(Double(minX + maxX + 1) / 2 - centre) <= 1)
        #expect(abs(Double(minY + maxY + 1) / 2 - centre) <= 1)
    }

    @Test func aRowsHighlightGoesWhenThePointerMovesOn() {
        let row = MenuServerRow(title: "PS5", marks: (NSImage(), NSImage())) {}
        let selection = row.subviews.compactMap { $0 as? NSVisualEffectView }.first
        #expect(selection?.isHidden == true)
        row.isHovered = true
        #expect(selection?.isHidden == false)
        row.isHovered = false
        #expect(selection?.isHidden == true)
    }
}
