//
//  DualSenseFeedbackTests.swift
//
//  The DualSense OUTPUT report (framing and valid flags, as measured on a real
//  pad) and the haptics jitter buffer that feeds a USB pad's actuators.
//

import Foundation
import Testing

@testable import Glimmer

struct DualSenseOutputReportTests {

    @Test func triggersAreAlwaysAllowed() {
        let d = DualSenseHID.effectsState(DualSenseOutputState())
        #expect(d.count == 47)
        #expect(d[0] == 0x0C)     // right + left trigger, no rumble mode
        #expect(d[1] == 0)        // light bar untouched until the host sets it
    }

    @Test func triggerBlocksOnlyWhenAsked() {
        var s = DualSenseOutputState()
        s.rightTrigger = [0x26] + [UInt8](repeating: 7, count: 10)
        #expect(DualSenseHID.effectsState(s, triggers: false)[0] == 0)
        #expect(DualSenseHID.effectsState(s, triggers: true)[0] == 0x0C)
        s.rumbleLeft = 9
        #expect(DualSenseHID.effectsState(s, triggers: false)[0] == 0x03)
    }

    /// Only the side that changed is asserted: re-asserting the other side
    /// would restart the effect it is running.
    @Test func oneTriggerSideAtATime() {
        var s = DualSenseOutputState()
        s.rightTrigger = [0x26] + [UInt8](repeating: 7, count: 10)
        s.leftTrigger = [0x21] + [UInt8](repeating: 3, count: 10)
        let right = DualSenseHID.effectsState(s, triggerFlags: 0x04)
        #expect(right[0] == 0x04)
        #expect(right[10] == 0x26)
        #expect(DualSenseHID.effectsState(s, triggerFlags: 0x08)[0] == 0x08)
        #expect(DualSenseHID.effectsState(s, triggerFlags: 0xFF)[0] == 0x0C)   // only trigger bits
    }

    @Test func micLightOnlyWhenSetAndLeavesHapticsAlone() {
        var s = DualSenseOutputState()
        s.audioHaptics = true
        #expect(DualSenseHID.effectsState(s)[1] & 0x01 == 0)
        s.micLED = true
        var d = DualSenseHID.effectsState(s)
        #expect(d[1] == 0x01 | 0x02 | 0x20 | 0x40)
        #expect(d[8] == 1 && d[9] == 0)     // light on; nothing muted at the pad
        s.micLED = false
        d = DualSenseHID.effectsState(s)
        #expect(d[1] & 0x01 == 0x01 && d[8] == 0)
    }

    @Test func rumbleBitsOnlyWhileRumbling() {
        var s = DualSenseOutputState()
        s.rumbleLeft = 200; s.rumbleRight = 10
        let d = DualSenseHID.effectsState(s)
        #expect(d[0] == 0x0F)
        #expect(d[2] == 10 && d[3] == 200)
        // Stopped: the bits go, which also stops the motors.
        s.rumbleLeft = 0; s.rumbleRight = 0
        #expect(DualSenseHID.effectsState(s)[0] == 0x0C)
    }

    @Test func actuatorHapticsAskForFullPowerAndTheFilter() {
        var s = DualSenseOutputState()
        s.audioHaptics = true
        let d = DualSenseHID.effectsState(s)
        #expect(d[1] == 0x02 | 0x20 | 0x40)
        #expect(d[36] == 0 && d[39] == 0x01 && d[9] == 0)
        // The keepalive repeats them without touching the triggers.
        #expect(DualSenseHID.hapticsKeepAliveState(s)?[0] == 0)
        #expect(DualSenseHID.hapticsKeepAliveState(s)?[1] == 0x62)
        s.rumbleLeft = 9
        #expect(DualSenseHID.hapticsKeepAliveState(s) == nil)
    }

    @Test func lightbarIntensityAndTriggerBlocks() {
        var s = DualSenseOutputState()
        s.lightSet = true; s.lightR = 1; s.lightG = 2; s.lightB = 3
        s.intensity = 0x62
        s.rightTrigger = [0x21] + [UInt8](repeating: 0xAA, count: 10)
        s.leftTrigger = [0x26] + [UInt8](repeating: 0xBB, count: 10)
        let d = DualSenseHID.effectsState(s)
        #expect(d[1] == 0x44)
        #expect(Array(d[44...46]) == [1, 2, 3])
        #expect(d[36] == 0x62)
        #expect(d[10] == 0x21 && d[20] == 0xAA)
        #expect(d[21] == 0x26 && d[31] == 0xBB)
    }

    @Test func usbReportStartsWithItsID() {
        let effects = [UInt8](repeating: 7, count: 47)
        let (id, bytes) = DualSenseHID.outputReport(effects: effects, bluetooth: false)
        #expect(id == 0x02)
        #expect(bytes.count == 48)
        #expect(bytes[0] == 0x02 && bytes[1] == 7)
    }

    @Test func bluetoothReportCarriesTagAndCRC() {
        let effects = [UInt8](repeating: 7, count: 47)
        let (id, bytes) = DualSenseHID.outputReport(effects: effects, bluetooth: true)
        #expect(id == 0x31)
        #expect(bytes.count == 78)
        #expect(bytes[0] == 0x31 && bytes[1] == 0x02 && bytes[2] == 7 && bytes[48] == 7 && bytes[49] == 0)
        let crc = DualSenseHID.bluetoothCRC(bytes[0..<74])
        let stored = UInt32(bytes[74]) | UInt32(bytes[75]) << 8 | UInt32(bytes[76]) << 16 | UInt32(bytes[77]) << 24
        #expect(crc == stored)
    }

    @Test func crcMatchesTheStandardCheckValue() {
        // CRC-32 of "123456789" is 0xCBF43926; ours prepends the 0xA2 seed byte,
        // so check the seed path against a direct computation instead.
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in [UInt8(0xA2)] + Array("123456789".utf8) {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : (crc >> 1) }
        }
        #expect(DualSenseHID.bluetoothCRC(ArraySlice(Array("123456789".utf8))) == crc ^ 0xFFFF_FFFF)
    }

    @Test func intensityNibbles() {
        #expect(PlayStationBackend.intensityNibbles(Strong) == (0x00, 0x00))
        #expect(PlayStationBackend.intensityNibbles(Medium) == (0x02, 0x40))
        #expect(PlayStationBackend.intensityNibbles(Weak) == (0x03, 0x50))
        #expect(PlayStationBackend.intensityNibbles(Off) == (0x0F, 0xF0))
    }
}

struct HapticsBufferTests {

    /// One 10 ms console frame: 30 stereo Int16 samples of `value`.
    private func frame(_ value: Int16 = 16_384) -> [UInt8] {
        var bytes: [UInt8] = []
        for _ in 0..<30 {
            for v in [value, value] { bytes += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }
        }
        return bytes
    }

    private func push(_ b: inout HapticsBuffer, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { b.push($0) }
    }

    @discardableResult
    private func render(_ b: inout HapticsBuffer, _ frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        b.render(frames: frames) { i, l, _ in out[i] = l }
        return out
    }

    @Test func upsamplesTenMillisecondsToFourHundredEightyFrames() {
        var b = HapticsBuffer(outputRate: 48_000)
        push(&b, frame())
        #expect(b.queued == 480)
    }

    @Test func waitsForTheTargetThenPlays() {
        var b = HapticsBuffer(outputRate: 48_000, targetMs: 30)
        push(&b, frame()); push(&b, frame())             // 20 ms queued
        let silent = render(&b, 128)
        #expect(!b.playing)
        #expect(silent.allSatisfy { $0 == 0 })
        push(&b, frame())                                  // 30 ms queued: still waits
        render(&b, 1200)                                   // 27.7 ms since the first frame
        #expect(!b.playing)
        let out = render(&b, 960)                          // passes 30 ms: plays
        #expect(b.playing)
        #expect(abs(out[900] - 0.5) < 0.01)                // settled through the low-pass
    }

    /// The console's bursts (two frames 4 ms apart, then ~17 ms of nothing)
    /// must not start a run early just because a burst filled the target.
    @Test func aBurstThatFillsTheTargetStillWaitsTheTarget() {
        var b = HapticsBuffer(outputRate: 48_000, targetMs: 15)
        push(&b, frame()); push(&b, frame())             // 20 ms in one burst > 15 ms target
        render(&b, 192)                                    // 4 ms later
        #expect(!b.playing)
        render(&b, 576)                                    // 16 ms: has waited 15
        #expect(b.playing)
    }

    @Test func aShortEffectPlaysOnceItHasWaitedTheTarget() {
        var b = HapticsBuffer(outputRate: 48_000, targetMs: 30)
        push(&b, frame())                                  // a 10 ms tap, less than the target
        render(&b, 960)                                    // 20 ms: still waiting
        #expect(!b.playing)
        let out = render(&b, 960)                          // 40 ms: has waited 30, plays
        #expect(out.prefix(480).allSatisfy { $0 == 0 })   // exactly 30 ms after it arrived
        #expect(out[700] > 0.05)                           // (rising through the filter: 2 ms delay)
        render(&b, 64)
        #expect(b.runs == 1)                               // then ran out,
        #expect(b.cutRuns == 1)                            // mid-signal: a constant never decays
    }

    @Test func theTargetIsSetFromOutside() {
        var b = HapticsBuffer(outputRate: 48_000, targetMs: 30)
        b.setTarget(ms: 80)
        #expect(b.targetFrames == 3840)
    }

    @Test func aFloodIsTrimmedBackToTheTarget() {
        var b = HapticsBuffer(outputRate: 48_000, targetMs: 30, extraMs: 50)
        for _ in 0..<20 { push(&b, frame()) }              // 200 ms at once
        #expect(b.queued <= b.targetFrames + b.maxExtraFrames)
    }

    @Test func gainZeroMutes() {
        var b = HapticsBuffer(outputRate: 48_000, targetMs: 10)
        b.gain = 0
        for _ in 0..<3 { push(&b, frame()) }
        #expect(render(&b, 960).allSatisfy { $0 == 0 })
    }
}

struct ArrivalJitterTests {

    @Test func needsFiftyGapsBeforeItAnswers() {
        var j = ArrivalJitter()
        for _ in 0..<49 { j.add(gapMs: 10) }
        #expect(j.hapticsTargetMs == nil)
        j.add(gapMs: 10)
        #expect(j.hapticsTargetMs == 15)                   // steady wired stream: the floor
    }

    @Test func burstyDeliverySetsTheTarget() {
        // Wi-Fi: four frames at once every 40 ms.
        var j = ArrivalJitter()
        for _ in 0..<100 { for g in [40.0, 0, 0, 0] { j.add(gapMs: g) } }
        #expect(j.hapticsTargetMs == 45)
    }

    @Test func silencePausesAndRareStallsDontCount() {
        var j = ArrivalJitter()
        for i in 0..<400 { j.add(gapMs: i == 200 ? 120 : 10) }
        j.add(gapMs: 2_000)                                // the console paused for silence
        #expect(j.count == 400)
        #expect(j.hapticsTargetMs == 15)
    }
}

struct DualSenseBluetoothHapticsTests {

    @Test func reportLayoutIsDS5DonglesDoubleBlock() {
        let samples = (0..<128).map { Int8(truncatingIfNeeded: $0 - 64) }
        let r = DualSenseBluetoothHaptics.report(samples: samples, sequence: 3, counter: 10)
        #expect(r.count == 142)
        #expect(Array(r[0...9]) == [0x32, 0x30, 0x91, 4, 0x66, 48, 48, 10, 0xD2, 0x40])
        #expect(r[10] == UInt8(bitPattern: -64) && r[137] == 63)
        let crc = DualSenseHID.bluetoothCRC(r[0..<138])
        #expect(UInt32(r[138]) | UInt32(r[139]) << 8 | UInt32(r[140]) << 16 | UInt32(r[141]) << 24 == crc)
    }

    @Test func samplesBecomeSignedEightBit() {
        #expect(DualSenseBluetoothHaptics.s8(0) == 0)
        #expect(DualSenseBluetoothHaptics.s8(0.5) == 64)
        #expect(DualSenseBluetoothHaptics.s8(-1) == -127)
        #expect(DualSenseBluetoothHaptics.s8(1) == 127)
    }

    @Test func atTheConsolesRateTheBufferPassesSamplesThrough() {
        var b = HapticsBuffer(outputRate: 3000, targetMs: 0)
        var bytes: [UInt8] = []
        for v: Int16 in [0, 8192, 16_384, -16_384] {
            bytes += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
            bytes += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
        }
        bytes.withUnsafeBytes { b.push($0) }
        var out: [Float] = []
        b.render(frames: 4) { _, l, _ in out.append(l) }
        // One sample of delay from the interpolator, no filtering.
        #expect(out == [0, 0, 0.25, 0.5])
    }
}

struct GameModeBoostTests {
    @Test func readsGamepolicyctlStatus() {
        #expect(GameModeBoost.parsePolicy("Game mode is off.\nGame mode enablement policy is currently automatic. The system must meet all specified requirements to enable game mode.") == .automatic)
        #expect(GameModeBoost.parsePolicy("Game mode is on.\nGame mode enablement policy is currently disabled. Game mode is forced always on.") == .forcedOn)
        #expect(GameModeBoost.parsePolicy("") == .unknown)
    }
}

struct PadMotionTests {
    @Test func turningThePadTurnsItsOrientation() {
        var m = PadMotion()
        var rest = ChiakiControllerState()
        chiaki_controller_state_set_idle(&rest)
        // At rest, then one second of a 90°/s yaw at 200 Hz.
        m.accel(0, 1, 0, at: 0)
        m.gyro(0, 0, 0, at: 5_000)
        chiaki_orientation_tracker_apply_to_controller_state(&m.tracker, &rest)
        var turned = rest
        for i in 0..<200 {
            m.gyro(0, .pi / 2, 0, at: UInt32(10_000 + i * 5_000))
        }
        chiaki_orientation_tracker_apply_to_controller_state(&m.tracker, &turned)
        let moved = abs(turned.orient_y - rest.orient_y) + abs(turned.orient_w - rest.orient_w)
            + abs(turned.orient_x - rest.orient_x) + abs(turned.orient_z - rest.orient_z)
        #expect(moved > 0.3)
        #expect(abs(turned.gyro_y - .pi / 2) < 0.001)
    }

    @Test func recenterMakesThePoseLevel() {
        var m = PadMotion()
        m.accel(0.5, 0.8, 0.2, at: 0)
        m.recenter()
        #expect(abs(m.tracker.accel_y - 1) < 0.001)
        #expect(abs(m.tracker.accel_x) < 0.001)
    }
}

@MainActor
struct PlayStationSettingsTests {
    @Test func persistsSeparatelyFromSunshineAndClamps() {
        let defaults = UserDefaults(suiteName: "PlayStationSettingsTests")!
        defaults.removePersistentDomain(forName: "PlayStationSettingsTests")
        let a = PlayStationSettings(defaults: defaults)
        #expect(a.snapshot.bitrateKbps == nil)          // automatic by default
        a.bitrateAuto = false
        a.bitrateMbps = 250                               // over the console's range
        a.haptics = .rumble
        a.presentation = .smooth
        #expect(a.bitrateMbps == 100)
        let b = PlayStationSettings(defaults: defaults)
        #expect(b.snapshot.bitrateKbps == 100_000)
        #expect(b.haptics == .rumble && !b.snapshot.presentsDirect)
        #expect(defaults.object(forKey: "PS5.bitrateMbps") as? Int == 100)
    }
}

struct PolyphaseUpsamplerTests {
    /// Amplitude of `hz` in a 48 kHz signal, by correlation.
    private func amplitude(_ signal: [Float], hz: Double) -> Double {
        var re = 0.0, im = 0.0
        for (n, v) in signal.enumerated() {
            let w = 2 * Double.pi * hz * Double(n) / 48_000
            re += Double(v) * cos(w); im += Double(v) * sin(w)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(signal.count)
    }

    private func upsample(sineAt hz: Double, seconds: Double = 1) -> [Float] {
        var up = PolyphaseUpsampler(factor: 16)
        var out: [Float] = []
        for n in 0..<Int(3000 * seconds) {
            let v = Float(0.5 * sin(2 * .pi * hz * Double(n) / 3000))
            up.push(v, v) { l, _ in out.append(l) }
        }
        return Array(out.dropFirst(480))   // past the filter's start-up
    }

    @Test func unityAtDC() {
        var up = PolyphaseUpsampler(factor: 16)
        var last: Float = 0
        for _ in 0..<40 { up.push(0.5, 0.5) { l, _ in last = l } }
        #expect(abs(last - 0.5) < 0.001)
    }

    @Test func keepsTheTopOfTheBand() {
        // 1 kHz comes through within 1 dB (linear + biquad lost ~5 dB there).
        let a = amplitude(upsample(sineAt: 1000), hz: 1000)
        #expect(a > 0.5 * 0.89 && a < 0.5 * 1.12)
        // Its image at 3 kHz - 1 kHz = 2 kHz is at least 26 dB down.
        let image = amplitude(upsample(sineAt: 1000), hz: 2000)
        #expect(image < 0.5 * 0.05)
    }

    @Test func bufferUsesItAtFortyEightKilohertz() {
        var b = HapticsBuffer(outputRate: 48_000, targetMs: 0)
        let frame = [Int16](repeating: 8000, count: 60)   // 30 stereo samples
        frame.withUnsafeBytes { b.push($0) }
        #expect(b.queued == 480)
    }
}
