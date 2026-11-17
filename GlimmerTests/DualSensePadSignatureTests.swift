//
//  DualSensePadSignatureTests.swift
//
//  Two DualSenses: each raw report's GameController-visible buttons become a
//  PadSignature that ties the physical pad to its GameController slot. Pins
//  the face/D-pad byte (LX+7: hat low nibble, square 0x10, cross 0x20,
//  circle 0x40, triangle 0x80) and the shoulder byte (LX+8: L1 0x01, R1 0x02,
//  L3 0x40, R3 0x80), USB and Bluetooth.
//

import Testing
@testable import Glimmer

struct DualSensePadSignatureTests {
    private func decode(_ bytes: [UInt8], reportID: UInt32) -> DualSenseDecodedReport? {
        bytes.withUnsafeBufferPointer { DualSenseHID.decodeInputReport(reportID: reportID, bytes: $0) }
    }

    @Test func hatDirectionsAndFaceButtons() {
        #expect(PadSignature.fromRaw(face: 0x08, shoulders: 0) == 0)
        #expect(PadSignature.fromRaw(face: 0x00, shoulders: 0) == PadSignature.up)
        #expect(PadSignature.fromRaw(face: 0x03, shoulders: 0) == PadSignature.down | PadSignature.right)
        #expect(PadSignature.fromRaw(face: 0x07, shoulders: 0) == PadSignature.up | PadSignature.left)
        #expect(PadSignature.fromRaw(face: 0xF8, shoulders: 0)
                == PadSignature.cross | PadSignature.circle | PadSignature.square | PadSignature.triangle)
        #expect(PadSignature.fromRaw(face: 0x08, shoulders: 0xC3)
                == PadSignature.l1 | PadSignature.r1 | PadSignature.l3 | PadSignature.r3)
        // Create / Options / L2 / R2 bits are not GameController-visible here.
        #expect(PadSignature.fromRaw(face: 0x08, shoulders: 0x3C) == 0)
    }

    @Test func usbReportCarriesTheSignature() {
        var r = [UInt8](repeating: 0, count: 64)
        r[0] = 0x01
        r[8] = 0x22          // cross, hat right
        r[9] = 0x01          // L1
        #expect(decode(r, reportID: 0x01)?.signature == PadSignature.cross | PadSignature.right | PadSignature.l1)
    }

    @Test func bluetoothReportCarriesTheSignatureOneByteLater() {
        var r = [UInt8](repeating: 0, count: 78)
        r[0] = 0x31; r[1] = 0x01
        r[9] = 0x84          // triangle, hat down
        #expect(decode(r, reportID: 0x31)?.signature == PadSignature.triangle | PadSignature.down)
    }

    @Test func mergedButtonsOrEveryPad() {
        let a = DualSenseExtraButtons(options: true, create: false, ps: false, mute: false, l1: false, r1: false)
        let b = DualSenseExtraButtons(options: false, create: false, ps: true, mute: false, l1: false, r1: true)
        let m = DualSenseHID.merged([a, b])
        #expect(m.options && m.ps && m.r1 && !m.create && !m.mute && !m.l1)
    }
}

struct DualSenseAudioDeviceTests {
    @Test func usbAudioUIDCarriesTheHIDLocation() {
        let uid = "AppleUSBAudioEngine:Sony Interactive Entertainment:DualSense Wireless Controller:3100000:1"
        #expect(DualSenseAudioHaptics.uid(uid, isAt: 0x3100000))
        #expect(!DualSenseAudioHaptics.uid(uid, isAt: 0x100000))
        #expect(DualSenseAudioHaptics.uid("AppleUSBAudioEngine:Sony:DualSense:100000:2", isAt: 0x100000))
    }
}

struct DualSenseRawAxesTests {
    @Test func sticksAreLinearFullRange() {
        #expect(DualSenseRawAxes.stick(0) == -32768)
        #expect(DualSenseRawAxes.stick(255) == 32767)
        #expect(abs(Int(DualSenseRawAxes.stick(128))) < 300)
        // GameStream Y is up; the report's is down.
        #expect(DualSenseRawAxes.stickY(0) == 32767)
        #expect(DualSenseRawAxes.stickY(255) == -32768)
    }

    @Test func usbReportCarriesTheAxes() {
        var r = [UInt8](repeating: 0, count: 64)
        r[0] = 0x01
        r[1] = 10; r[2] = 20; r[3] = 30; r[4] = 40; r[5] = 50; r[6] = 60
        r[8] = 0x08
        let axes = r.withUnsafeBufferPointer { DualSenseHID.decodeInputReport(reportID: 0x01, bytes: $0) }?.axes
        #expect(axes == DualSenseRawAxes(lx: 10, ly: 20, rx: 30, ry: 40, l2: 50, r2: 60))
    }

    @Test func usbRumbleKeepsHapticsLikeSony() {
        var s = DualSenseOutputState()
        s.rumbleLeft = 200; s.rumbleRight = 100
        s.audioHaptics = true; s.hapticsFilter = false; s.rumbleKeepsHaptics = true
        let d = DualSenseHID.effectsState(s, triggerFlags: 0)
        #expect(d[0] & 0x01 != 0 && d[0] & 0x02 == 0)
        #expect(d[38] & 0x08 != 0)
        #expect(d[3] == 200 && d[2] == 100)
        s.rumbleKeepsHaptics = false
        #expect(DualSenseHID.effectsState(s, triggerFlags: 0)[0] & 0x03 == 0x03)
    }
}
