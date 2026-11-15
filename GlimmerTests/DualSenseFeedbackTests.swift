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

    @Test func rumbleBitsOnlyWhileRumbling() {
        var s = DualSenseOutputState()
        s.rumbleLeft = 200; s.rumbleRight = 10
        let d = DualSenseHID.effectsState(s)
        #expect(d[0] == 0x0F)
        #expect(d[2] == 10 && d[3] == 200)
        // Audio haptics: never ask for rumble emulation, it mutes them.
        s.audioHaptics = true
        let h = DualSenseHID.effectsState(s)
        #expect(h[0] == 0x0C)
        #expect(h[2] == 0 && h[3] == 0)
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
        #expect(PlayStationBackend.intensityNibbles(Medium) == (0x02, 0x60))
        #expect(PlayStationBackend.intensityNibbles(Weak) == (0x03, 0x90))
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
        push(&b, frame())                                  // 30 ms: starts
        let out = render(&b, 960)
        #expect(b.playing)
        #expect(abs(out[900] - 0.5) < 0.01)                // settled through the low-pass
    }

    @Test func aShortEffectPlaysOnceItHasWaitedTheTarget() {
        var b = HapticsBuffer(outputRate: 48_000, targetMs: 30)
        push(&b, frame())                                  // a 10 ms tap, less than the target
        render(&b, 960)                                    // 20 ms: still waiting
        #expect(!b.playing)
        let out = render(&b, 960)                          // 40 ms: has waited 30, plays
        #expect(out.prefix(480).allSatisfy { $0 == 0 })   // exactly 30 ms after it arrived
        #expect(out[520] > 0.05)                           // (rising from 0 through the low-pass)
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
