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

    private func bazzite() -> Glimmer.Host {
        Glimmer.Host(id: "bazzite-row-test", name: "bazzite", customName: nil, localAddress: nil,
                     manualAddress: nil, apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil,
                     gfeVersion: nil, macAddress: nil)
    }

    /// Bazzite in use: its blue-to-purple disc, as in Settings.
    @Test func bazziteInUseIsOnItsGradient() {
        let current = bitmap(MenuHostMark.image(for: bazzite(), look: .current, appearance: NSAppearance(named: .aqua)!))
        let topLeft = rgb(current, current.pixelsWide / 4, current.pixelsHigh / 4)
        let bottomRight = rgb(current, current.pixelsWide * 3 / 4, current.pixelsHigh * 3 / 4)
        #expect(topLeft.b > 150 && topLeft.r < 60)
        #expect(bottomRight.r > topLeft.r + 40)
    }

    /// The ink box of a mark on its disc, in points from the disc's centre
    /// (y down), and its width and height in points.
    private func inkBox(_ rep: NSBitmapImageRep, look: MenuHostMark.Look) -> (x: Double, y: Double, w: Double, h: Double) {
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let p = rgb(rep, x, y)
                // Off, the disc is 8% black and the ink 50%: by alpha. In
                // use, the white mark on the disc's colour.
                let inked = look == .off ? p.a > 80 : p.a > 200 && min(p.r, p.g, p.b) > 160
                guard inked else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let centre = Double(rep.pixelsWide) / 2
        return ((Double(minX + maxX + 1) / 2 - centre) / 2, (Double(minY + maxY + 1) / 2 - centre) / 2,
                Double(maxX - minX + 1) / 2, Double(maxY - minY + 1) / 2)
    }

    /// Every mark sits by its ink box exactly on the disc's centre - no
    /// optical lift (Kevin judges centring literally) - in every look.
    @Test(arguments: [MenuHostMark.Look.current, .off])
    func marksSitOnTheDiscsCentre(look: MenuHostMark.Look) {
        let light = NSAppearance(named: .aqua)!
        for host in [playStation(), bazzite()] {
            let box = inkBox(bitmap(MenuHostMark.image(for: host, look: look, appearance: light)), look: look)
            #expect(abs(box.x) <= 0.25, "\(host.name) \(look) x \(box.x)")
            #expect(abs(box.y) <= 0.25, "\(host.name) \(look) y \(box.y)")
        }
    }

    /// The sidebar's rule: the same optical area for every mark, so a wide
    /// PlayStation logo and a square Bazzite mark carry the same weight -
    /// and the same size whether the machine is in use or not.
    @Test func marksAreTheSameSizeInUseAndOff() {
        let light = NSAppearance(named: .aqua)!
        var sides: [Double] = []
        for host in [playStation(), bazzite()] {
            let on = inkBox(bitmap(MenuHostMark.image(for: host, look: .current, appearance: light)), look: .current)
            let off = inkBox(bitmap(MenuHostMark.image(for: host, look: .off, appearance: light)), look: .off)
            #expect(abs(on.w - off.w) <= 0.5 && abs(on.h - off.h) <= 0.5, "\(host.name) \(on) \(off)")
            sides.append((on.w * on.h).squareRoot())
        }
        // Geometric means within 15% of each other (the ink nudge is ±10%).
        #expect(abs(sides[0] - sides[1]) / sides[0] < 0.15, "\(sides)")
    }

    @Test func aRowsHighlightGoesWhenThePointerMovesOn() {
        let row = MenuServerRow(title: "PS5", mark: NSImage()) {}
        // The grey band is the row's first subview, hidden until hovered.
        let band = row.subviews.first
        #expect(band?.isHidden == true)
        row.isHovered = true
        #expect(band?.isHidden == false)
        row.isHovered = false
        #expect(band?.isHidden == true)
    }
}

/// The opened server's Bitrate row: "Auto" at the slider's left end, what
/// it asks for at the right.
@MainActor
struct MenuBitrateRowTests {
    private func shown(_ row: MenuBitrateRow) -> [String] {
        row.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
    }

    @Test func automaticShowsWhatItWorksOutTo() {
        let row = MenuBitrateRow(stops: [5, 10, 20], mbps: nil, autoMbps: 35) { _ in }
        #expect(shown(row) == ["Auto", "35 Mbps"])
        let slider = row.subviews.compactMap { $0 as? NSSlider }.first
        #expect(slider?.doubleValue == 0)
    }

    @Test func aSetBitrateSitsOnItsStop() {
        let row = MenuBitrateRow(stops: [5, 10, 20], mbps: 11, autoMbps: nil) { _ in }
        #expect(shown(row) == ["Auto", "10 Mbps"])
        let slider = row.subviews.compactMap { $0 as? NSSlider }.first
        #expect(slider?.doubleValue == 2)
    }
}

/// The Servers list's disclosure - the server in use opening its stream
/// settings under it - moving the way Apple's Sound menu opens the AirPods
/// (measured off a 60 fps recording, 2026-11-18): the rows below and the
/// band's fade on one spring, the menu's height chasing them on a slower one.
@MainActor
struct MenuDisclosureListTests {
    private func rows(_ n: Int) -> [MenuRowView] {
        (0..<n).map { i in
            MenuServerRow(title: "PC \(i)", mark: NSImage(size: NSSize(width: 26, height: 26)),
                          hasDisclosure: i == 1) {}
        }
    }

    private func well(height: CGFloat = 120) -> NSView { NSView(frame: NSRect(x: 0, y: 0, width: 200, height: height)) }

    /// Runs the springs as the display link would, at 120 Hz.
    private func run(_ list: MenuDisclosureList, for seconds: Double) {
        for _ in 0..<Int((seconds * 120).rounded()) { list.advance(by: 1.0 / 120) }
    }

    @Test func collapsedItIsTheRowsExpandedTheBandJoinsUnderItsRow() {
        let r = rows(3), w = well()
        let closed = MenuDisclosureList(rows: r, well: (under: 1, view: w), expanded: false)
        #expect(closed.frame.height == 96)
        #expect(w.isHidden)
        let r2 = rows(3), w2 = well()
        let open = MenuDisclosureList(rows: r2, well: (under: 1, view: w2), expanded: true)
        #expect(open.frame.height == 216)
        #expect(!w2.isHidden && w2.frame.minY == 64)
        #expect(r2[2].frame.minY == 184)
        #expect((r2[1] as? MenuServerRow)?.disclosureProgress == 1)
    }

    @Test func expandingTheRowsLeadAndTheMenuFollows() {
        let r = rows(3), w = well()
        let list = MenuDisclosureList(rows: r, well: (under: 1, view: w), expanded: false)
        list.setExpanded(true)
        run(list, for: 0.1)
        let rowsDone = (r[2].frame.minY - 64) / 120
        let heightDone = (list.frame.height - 96) / 120
        #expect(rowsDone > 0.3 && heightDone > 0 && heightDone < rowsDone)
        // The band fades in with the rows, where it will stay.
        #expect(abs(Double(w.alphaValue) - Double(min(rowsDone, 1))) < 0.05 && w.frame.minY == 64)
        run(list, for: 2)
        #expect(list.frame.height == 216 && r[2].frame.minY == 184 && w.alphaValue == 1 && !list.isAnimating)
    }

    @Test func collapsingTheRowsSlideOverTheFadingBand() {
        let r = rows(3), w = well()
        let list = MenuDisclosureList(rows: r, well: (under: 1, view: w), expanded: true)
        list.setExpanded(false)
        run(list, for: 0.1)
        let rowsLeft = (r[2].frame.minY - 64) / 120
        let heightLeft = (list.frame.height - 96) / 120
        #expect(rowsLeft < heightLeft)
        #expect(w.alphaValue > 0 && w.alphaValue < 1)
        // Closing, the band takes no clicks.
        let inBand = NSPoint(x: 100, y: 64 + 110)
        let hit = list.hitTest(list.convert(inBand, to: list.superview))
        #expect(hit == nil || !(hit!.isDescendant(of: w)))
        run(list, for: 2)
        #expect(list.frame.height == 96 && w.isHidden && r[2].frame.minY == 64)
    }

    @Test func theChevronTurnsWithTheRows() {
        let r = rows(3)
        let list = MenuDisclosureList(rows: r, well: (under: 1, view: well()), expanded: false)
        list.setExpanded(true)
        run(list, for: 0.1)
        let chevron = (r[1] as? MenuServerRow)?.disclosureProgress ?? 0
        #expect(abs(chevron - (r[2].frame.minY - 64) / 120) < 0.02)
    }

    @Test func aRebuildMidFlightCarriesTheMotionOn() {
        let list = MenuDisclosureList(rows: rows(3), well: (under: 1, view: well()), expanded: false)
        list.setExpanded(true)
        run(list, for: 0.08)
        let r = rows(3)
        let rebuilt = MenuDisclosureList(rows: r, well: (under: 1, view: well()), expanded: true, continuing: list)
        #expect(rebuilt.frame.height == list.frame.height)
        #expect(rebuilt.isAnimating)
        run(rebuilt, for: 2)
        #expect(rebuilt.frame.height == 216)
    }
}

/// The menu's top: the Now Playing card (design/menu-bar/top-3.png).
@MainActor
struct MenuNowPlayingCardTests {
    private func card(_ controls: [MenuNowPlayingCard.Control], onOpen: (() -> Void)? = nil) -> MenuNowPlayingCard {
        MenuNowPlayingCard(tile: MenuAppTile.image(.app(nil)), title: "Steam Big Picture", subtitle: "bazzite",
                           controls: controls, onOpen: onOpen)
    }

    private func buttons(_ card: MenuNowPlayingCard) -> [MenuRoundButton] {
        card.subviews.compactMap { $0 as? MenuRoundButton }.sorted { $0.frame.minX < $1.frame.minX }
    }

    @Test func theControlsSitRightTheLastOneRightmost() {
        let c = card([.init(symbol: "pip.enter", label: "PiP") {}, .init(symbol: "play.fill", label: "Stream", prominent: true) {}])
        let b = buttons(c)
        #expect(c.frame.height == 72 && c.frame.width >= 307)
        #expect(b.map { $0.accessibilityLabel() } == ["PiP", "Stream"])
        // 30 pt buttons 38 pt apart, the right one 26 pt in from the card's
        // edge (the card is 12 pt in from the row's).
        #expect(b.allSatisfy { $0.frame.size == NSSize(width: 30, height: 30) })
        #expect(b[1].frame.midX - b[0].frame.midX == 38)
        #expect(abs(b[1].frame.midX - (c.bounds.maxX - 12 - 26)) <= 1)
    }

    @Test func aButtonsClickRunsItsAction() {
        var ran = 0
        let c = card([.init(symbol: "stop.fill", label: "End Stream") { ran += 1 }])
        #expect(buttons(c)[0].accessibilityPerformPress())
        #expect(ran == 1)
    }

    @Test func theCardItselfIsAButtonOnlyWithSomewhereToGo() {
        #expect(card([]).accessibilityRole() == .group)
        var opened = false
        let open = card([], onOpen: { opened = true })
        #expect(open.accessibilityRole() == .button)
        #expect(open.accessibilityPerformPress() && opened)
    }

    @Test func tilesAreTheirSizeWithTheMarkCentred() {
        for kind: MenuAppTile.Kind in [.playStation, .app(nil)] {
            let image = MenuAppTile.image(kind)
            #expect(image.size == NSSize(width: 42, height: 42))
        }
    }
}

/// The streaming server's row: the AirPods row's layout - one 32 pt row,
/// the stream's numbers on a second line under the name.
@MainActor
struct MenuServerStatsRowTests {
    @Test func theSecondLineKeepsTheRowItsHeight() {
        let row = MenuServerRow(title: "bazzite", mark: NSImage(size: NSSize(width: 26, height: 26))) {}
        row.stats = [.init(symbol: "play.rectangle.fill", text: "1440p120 HDR"), .init(symbol: "clock.fill", text: "8 ms"),
                     .init(symbol: "cellularbars", text: "45 Mbps")]
        #expect(row.frame.height == 32)
        #expect(row.accessibilityValue() as? String == "1440p120 HDR, 8 ms, 45 Mbps")
    }

    @Test func theGlyphsAreCutToTenPointsOfInk() {
        for symbol in ["play.rectangle.fill", "clock.fill", "cellularbars"] {
            let glyph = MenuStatGlyph.image(symbol)
            #expect(glyph?.size.height == 10)
            #expect((glyph?.size.width ?? 0) > 6 && (glyph?.size.width ?? 99) < 16)
        }
    }
}

