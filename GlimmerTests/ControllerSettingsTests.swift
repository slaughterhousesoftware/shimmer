//
//  ControllerSettingsTests.swift
//
//  One set of controller settings for every machine: the PS5 and the PC
//  streams both follow it, and a PS5's earlier choices carry over to it.
//

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
        #expect(ControllerSettings(defaults: defaults).vibration == .off)
        #expect(!ControllerSettings(defaults: defaults).adaptiveTriggers)
    }

    @Test func ownChoiceWinsOverAConsoles() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("rumble", forKey: "PS5.ps5-abc.haptics")
        ControllerSettings(defaults: defaults).vibration = .actuators
        #expect(ControllerSettings(defaults: defaults).vibration == .actuators)
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
        #expect(console.snapshot.haptics == .rumble)
        #expect(!console.snapshot.adaptiveTriggers)
        #expect(console.snapshot.lightBar)
    }
}

/// A PC stream honours the Controller tab: what the PC sends to the pad is
/// dropped when its switch is off. The settings reach the stream the way a
/// PS5's do - handed to its backend when the stream starts.
struct PCControllerFeedbackTests {
    private typealias Wire = EnetInboundOrderTests

    @Test func pcRumbleIsDroppedWhenVibrationIsOff() throws {
        let (channel, _) = try Wire.makeChannel()
        let events = Wire.rumbleEvents(channel)
        ControllerFeedbackGate.apply(ControllerSettings.Snapshot(vibration: .off), to: channel)
        channel.onDatagram(Wire.reliable(relSeq: 1, try Wire.rumble(1, seq: 1)))
        #expect(events.values.isEmpty)
    }

    @Test func pcRumbleArrivesWhenVibrationIsOn() throws {
        let (channel, _) = try Wire.makeChannel()
        let events = Wire.rumbleEvents(channel)
        ControllerFeedbackGate.apply(ControllerSettings.Snapshot(vibration: .rumble), to: channel)
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
            ControllerFeedbackGate.apply(allowed, to: channel)
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
        ControllerFeedbackGate.apply(ControllerSettings.Snapshot(adaptiveTriggers: false), to: channel)
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
