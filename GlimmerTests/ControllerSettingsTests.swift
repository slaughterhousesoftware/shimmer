//
//  ControllerSettingsTests.swift
//
//  One set of controller settings for every machine: the PS5 and the PC
//  streams both follow it, and a PS5's earlier choices carry over to it.
//

import AppKit
import Foundation
import Testing
@testable import Glimmer

@MainActor
struct ControllerSettingsTests {
    private func suite() throws -> (UserDefaults, String) {
        let name = "controller-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func defaultsAreEverythingOn() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ControllerSettings(defaults: defaults)
        #expect(settings.vibration == .actuators)
        #expect(settings.adaptiveTriggers)
        #expect(settings.lightBar)
    }

    @Test func choicesPersist() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let a = ControllerSettings(defaults: defaults)
        a.vibration = .off
        a.adaptiveTriggers = false
        a.lightBar = false
        let b = ControllerSettings(defaults: defaults)
        #expect(b.vibration == .off)
        #expect(!b.adaptiveTriggers)
        #expect(!b.lightBar)
    }

    @Test func aConsolesEarlierChoicesCarryOver() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("rumble", forKey: "PS5.ps5-abc.haptics")
        defaults.set(false, forKey: "PS5.ps5-abc.adaptiveTriggers")
        defaults.set(false, forKey: "PS5.ps5-abc.lightBar")
        ControllerSettings.migrateFromConsoles(["ps5-abc"], defaults: defaults)
        let settings = ControllerSettings(defaults: defaults)
        #expect(settings.vibration == .rumble)
        #expect(!settings.adaptiveTriggers)
        #expect(!settings.lightBar)
    }

    @Test func theOlderSharedPS5ChoicesCarryOverToo() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("off", forKey: "PS5.haptics")
        defaults.set(false, forKey: "PS5.adaptiveTriggers")
        ControllerSettings.migrateFromConsoles([], defaults: defaults)
        #expect(ControllerSettings(defaults: defaults).vibration == .off)
        #expect(!ControllerSettings(defaults: defaults).adaptiveTriggers)
    }

    /// A console that's no longer registered left its keys behind; they
    /// don't decide the settings for every machine.
    @Test func aForgottenConsolesLeftoversAreIgnored() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("off", forKey: "PS5.ps5-gone.haptics")
        ControllerSettings.migrateFromConsoles(["ps5-here"], defaults: defaults)
        #expect(ControllerSettings(defaults: defaults).vibration == .actuators)
    }

    /// The first registered console with a choice gives it.
    @Test func registeredConsolesAreReadInOrder() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("off", forKey: "PS5.ps5-b.haptics")
        defaults.set("rumble", forKey: "PS5.ps5-a.haptics")
        ControllerSettings.migrateFromConsoles(["ps5-b", "ps5-a"], defaults: defaults)
        #expect(ControllerSettings(defaults: defaults).vibration == .off)
    }

    @Test func ownChoiceWinsOverAConsoles() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("rumble", forKey: "PS5.ps5-abc.haptics")
        ControllerSettings(defaults: defaults).vibration = .actuators
        ControllerSettings.migrateFromConsoles(["ps5-abc"], defaults: defaults)
        #expect(ControllerSettings(defaults: defaults).vibration == .actuators)
    }

    /// Once moved, the old keys no longer matter.
    @Test func carriesOverOnlyOnce() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        ControllerSettings.migrateFromConsoles(["ps5-abc"], defaults: defaults)
        defaults.set("off", forKey: "PS5.ps5-abc.haptics")
        ControllerSettings.migrateFromConsoles(["ps5-abc"], defaults: defaults)
        #expect(ControllerSettings(defaults: defaults).vibration == .actuators)
    }

    /// An instance made before the move (the shared one, if the window was
    /// up first) picks up what was moved.
    @Test func anExistingInstanceSeesTheMove() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let early = ControllerSettings(defaults: defaults)
        defaults.set("rumble", forKey: "PS5.ps5-abc.haptics")
        ControllerSettings.migrateFromConsoles(["ps5-abc"], defaults: defaults, reloading: [early])
        #expect(early.vibration == .rumble)
    }

    /// The PC stream reads the settings on its own threads, not the main actor.
    @Test func snapshotReadsTheSameValuesOffTheMainActor() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ControllerSettings(defaults: defaults)
        settings.vibration = .off
        settings.lightBar = false
        let snapshot = ControllerSettings.Snapshot.load(defaults)
        #expect(snapshot == settings.snapshot)
        #expect(!snapshot.rumble)
        #expect(snapshot.adaptiveTriggers)
        #expect(!snapshot.lightBar)
    }

    @Test func rumbleStaysOnForEitherVibrationMode() {
        #expect(ControllerSettings.Snapshot(vibration: .actuators).rumble)
        #expect(ControllerSettings.Snapshot(vibration: .rumble).rumble)
        #expect(!ControllerSettings.Snapshot(vibration: .off).rumble)
    }

    /// A PS5 stream takes its feedback from the shared settings.
    @Test func playStationSnapshotFollowsTheSharedSettings() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = ControllerSettings(defaults: defaults)
        controller.vibration = .rumble
        controller.adaptiveTriggers = false
        let console = PlayStationSettings(hostID: "ps5-a", defaults: defaults, controller: controller)
        #expect(console.snapshot.controller == controller.snapshot)
    }

    /// Vibration Off stops a PS5's plain rumble (PS4 games, players 2-4)
    /// too, not only its haptics - the same as on a PC.
    @Test func vibrationOffStopsPlayStationRumble() {
        var settings = PlayStationSettings.Snapshot()
        #expect(settings.controller.rumble)
        settings.controller.vibration = .off
        #expect(!settings.controller.rumble)
    }
}

/// A PC stream honours the Controller tab: what the PC sends to the pad is
/// dropped when its switch is off. The settings reach the stream the way a
/// PS5's do - handed to its backend when the stream starts.
struct PCControllerFeedbackTests {
    private typealias Wire = EnetInboundOrderTests

    /// Passes the channel's feedback callbacks through the gate, as
    /// NativeBackend's wiring installs them.
    private func install(_ allowed: ControllerSettings.Snapshot, on channel: EnetControlChannel) {
        let gate = ControllerFeedbackGate(allowed: allowed)
        channel.onRumble = gate.rumble(channel.onRumble)
        channel.onRumbleTriggers = gate.rumble(channel.onRumbleTriggers)
        channel.onSetRgbLed = gate.lightBar(channel.onSetRgbLed)
        channel.onSetAdaptiveTriggers = gate.adaptiveTriggers(channel.onSetAdaptiveTriggers)
    }

    @Test func pcRumbleIsDroppedWhenVibrationIsOff() throws {
        let (channel, _) = try Wire.makeChannel()
        let events = Wire.rumbleEvents(channel)
        install(ControllerSettings.Snapshot(vibration: .off), on: channel)
        channel.onDatagram(Wire.reliable(relSeq: 1, try Wire.rumble(1, seq: 1)))
        #expect(events.values.isEmpty)
    }

    @Test func pcRumbleArrivesWhenVibrationIsOn() throws {
        let (channel, _) = try Wire.makeChannel()
        let events = Wire.rumbleEvents(channel)
        install(ControllerSettings.Snapshot(vibration: .rumble), on: channel)
        channel.onDatagram(Wire.reliable(relSeq: 1, try Wire.rumble(1, seq: 1)))
        #expect(events.values == [1])
    }

    @Test func lightAndTriggersFollowTheirSwitches() throws {
        for on in [false, true] {
            let (channel, _) = try Wire.makeChannel()
            var got: [String] = []
            channel.onSetRgbLed = { _, _, _, _ in got.append("light") }
            channel.onSetAdaptiveTriggers = { _, _, _, _, _, _ in got.append("triggers") }
            channel.onRumbleTriggers = { _, _, _ in got.append("trigger rumble") }
            let allowed = ControllerSettings.Snapshot(vibration: on ? .actuators : .off,
                                                      adaptiveTriggers: on, lightBar: on)
            install(allowed, on: channel)
            channel.onSetRgbLed?(0, 255, 0, 0)
            channel.onSetAdaptiveTriggers?(0, 0x0C, 1, 1, [], [])
            channel.onRumbleTriggers?(0, 100, 100)
            #expect(got == (on ? ["light", "triggers", "trigger rumble"] : []))
        }
    }

    @Test func eachSwitchOnlyGatesItsOwnFeedback() throws {
        let (channel, _) = try Wire.makeChannel()
        var got: [String] = []
        channel.onRumble = { _, _, _ in got.append("rumble") }
        channel.onSetRgbLed = { _, _, _, _ in got.append("light") }
        channel.onSetAdaptiveTriggers = { _, _, _, _, _, _ in got.append("triggers") }
        install(ControllerSettings.Snapshot(adaptiveTriggers: false), on: channel)
        channel.onRumble?(0, 1, 1)
        channel.onSetRgbLed?(0, 1, 2, 3)
        channel.onSetAdaptiveTriggers?(0, 0x0C, 1, 1, [], [])
        #expect(got == ["rumble", "light"])
    }

    @Test func aPCBackendKeepsTheSettingsItWasGiven() {
        let allowed = ControllerSettings.Snapshot(vibration: .off, adaptiveTriggers: false, lightBar: true)
        #expect(NativeBackend(controllerFeedback: allowed).controllerFeedback == allowed)
        #expect(NativeBackend().controllerFeedback == ControllerSettings.Snapshot())
    }
}

/// The Controller tab lists every connected pad the way System Settings'
/// Game Controllers does: the whole pad as Steam draws it, the name, its
/// state, and a button that opens that pane.
struct ControllerListTests {
    @Test func everyPadKindHasFullArt() {
        for kind in MenuBarBatteryGlyph.kinds {
            #expect(ControllerArt.assetName(kind: kind) == "ControllerArt-\(kind)")
            #expect(NSImage(named: ControllerArt.assetName(kind: kind)) != nil, "no art for \(kind)")
        }
        #expect(ControllerArt.assetName(kind: "anything") == "ControllerArt-generic")
    }

    @Test func statusLine() {
        #expect(ControllerEntry(id: 0, name: "Pad", kind: "ps5", battery: (85, false)).status
                == "Connected · 85% battery")
        #expect(ControllerEntry(id: 0, name: "Pad", kind: "ps5", battery: (40, true)).status
                == "Charging · 40%")
        #expect(ControllerEntry(id: 0, name: "Pad", kind: "xbox", battery: (70, nil)).status
                == "Connected · 70% battery")
        #expect(ControllerEntry(id: 0, name: "Pad", kind: "generic", battery: nil).status == "Connected")
    }

    @Test func opensSystemSettingsGameControllers() {
        #expect(ControllerTabPage.systemSettingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.Game-Controller-Settings.extension")
    }

    /// A raw-HID battery belongs to the DualSense only when it's the only one.
    @Test func dualSenseBatteryOnlyWhenUnambiguous() {
        #expect(ControllerEntry.hidBatteryApplies(kind: "ps5", dualSenseCount: 1))
        #expect(!ControllerEntry.hidBatteryApplies(kind: "ps5", dualSenseCount: 2))
        #expect(!ControllerEntry.hidBatteryApplies(kind: "xbox", dualSenseCount: 1))
    }
}
