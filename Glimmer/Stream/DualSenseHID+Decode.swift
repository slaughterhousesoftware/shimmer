//
//  DualSenseHID+Decode.swift
//
//  The pure, stateless half of the DualSense raw-HID reader: one input report
//  in, button bits + battery out. Topic split from DualSenseHID.swift (file-
//  length budget) and kept free of the manager, the lock, and IOKit so the unit
//  tests can feed it synthetic USB / Bluetooth byte arrays without a pad.
//

import Foundation

/// One decoded DualSense INPUT report: the button bits plus the battery field
/// when the report carries one (the 10-byte BT simple report does not).
struct DualSenseDecodedReport: Equatable, Sendable {
    var buttons: DualSenseExtraButtons
    var battery: DualSenseBattery?
    /// The buttons GameController also reports, as `PadSignature` bits - what
    /// ties this physical pad to its GameController slot (two players).
    var signature: UInt32 = 0
}

/// The buttons both GameController and the raw report carry, as one bitset:
/// when a slot's GameController state and one pad's raw report show the same
/// non-empty set, that pad is the slot's (DualSenseHID.noteGameControllerState).
enum PadSignature {
    static let cross: UInt32 = 1 << 0, circle: UInt32 = 1 << 1, square: UInt32 = 1 << 2, triangle: UInt32 = 1 << 3
    static let up: UInt32 = 1 << 4, down: UInt32 = 1 << 5, left: UInt32 = 1 << 6, right: UInt32 = 1 << 7
    static let l1: UInt32 = 1 << 8, r1: UInt32 = 1 << 9, l3: UInt32 = 1 << 10, r3: UInt32 = 1 << 11

    /// From the raw report's face/D-pad byte (low nibble the hat, 0 = up,
    /// clockwise, 8 = centred; 0x10 square, 0x20 cross, 0x40 circle, 0x80
    /// triangle) and the shoulder byte (L1 0x01, R1 0x02, L3 0x40, R3 0x80).
    static func fromRaw(face: UInt8, shoulders: UInt8) -> UInt32 {
        var s: UInt32 = 0
        if face & 0x10 != 0 { s |= square }
        if face & 0x20 != 0 { s |= cross }
        if face & 0x40 != 0 { s |= circle }
        if face & 0x80 != 0 { s |= triangle }
        switch face & 0x0F {
        case 0: s |= up
        case 1: s |= up | right
        case 2: s |= right
        case 3: s |= down | right
        case 4: s |= down
        case 5: s |= down | left
        case 6: s |= left
        case 7: s |= up | left
        default: break
        }
        if shoulders & 0x01 != 0 { s |= l1 }
        if shoulders & 0x02 != 0 { s |= r1 }
        if shoulders & 0x40 != 0 { s |= l3 }
        if shoulders & 0x80 != 0 { s |= r3 }
        return s
    }
}

extension DualSenseHID {

    /// Pure decode of one DualSense INPUT report (no state, no lock). Returns
    /// nil for anything that is not a DualSense state report: only IDs 0x01
    /// (USB full / BT simple) and 0x31 (BT full) carry the button bytes at the
    /// offsets below, so any other ID (0x05/0x09/0x20... feature echoes, a
    /// future firmware's extra reports) must NOT be read as button state - it
    /// would flip the decoded bits to garbage, fire onChange, and the chord
    /// path would cancel a live dwell on a phantom release. The 10-byte BT
    /// simple report fails the length guard (its buttons sit at a different
    /// offset) and is likewise ignored.
    ///
    /// Locating the button bytes: some IOKit stacks strip the report ID into
    /// `reportID` (so bytes[0] is the first payload byte); macOS leaves it at
    /// bytes[0] (measured: reportID == bytes[0] == 0x31 over BT). Detect by
    /// sniffing bytes[0] for a known DualSense report ID. Then:
    ///   USB (0x01): [ID?] LX LY RX RY ...   → LX at (idPresent ? 1 : 0)
    ///   BT  (0x31): [ID?] tag LX LY ...      → one extra tag byte before LX
    /// Button bytes sit a fixed distance after LX (identical masks USB/BT, per
    /// Linux hid-playstation / SDL ps5):
    ///   buttons[1] (L1 0x01 / R1 0x02 / Create 0x10 / Options 0x20) at LX+8
    ///   buttons[2] (PS 0x01 / Mute 0x04)                            at LX+9
    static func decodeInputReport(reportID: UInt32, bytes: UnsafeBufferPointer<UInt8>) -> DualSenseDecodedReport? {
        let length = bytes.count
        let idPresent = length > 0 && (bytes[0] == 0x01 || bytes[0] == 0x31)
        let rid = idPresent ? UInt32(bytes[0]) : reportID
        guard rid == 0x01 || rid == 0x31 else { return nil }
        let lxIndex = (idPresent ? 1 : 0) + (rid == 0x31 ? 1 : 0)
        let b1Index = lxIndex + 8
        let b2Index = lxIndex + 9
        guard length > b2Index else { return nil }

        let b1 = bytes[b1Index]
        let b2 = bytes[b2Index]
        var buttons = DualSenseExtraButtons()
        buttons.l1 = (b1 & 0x01) != 0
        buttons.r1 = (b1 & 0x02) != 0
        buttons.create = (b1 & 0x10) != 0
        buttons.options = (b1 & 0x20) != 0
        buttons.ps = (b2 & 0x01) != 0
        buttons.mute = (b2 & 0x04) != 0

        // Battery: the status byte sits 52 bytes past LX (SDL ps5 / Linux
        // hid-playstation). Low nibble = level 0...10 (percent ≈ level*10+5),
        // high nibble = charge state (1 = charging, 2 = full). The simple
        // 10-byte BT report has no battery field, so guard on length and on
        // the 0x0C "not reporting" sentinel.
        var battery: DualSenseBattery?
        let statusIndex = lxIndex + 52
        if length > statusIndex {
            let status = bytes[statusIndex]
            let level = status & 0x0F
            if level != 0x0C {
                let charge = (status >> 4) & 0x0F
                let pct = (charge == 0x02) ? 100 : min(Int(level) * 10 + 5, 100)
                battery = DualSenseBattery(percent: pct, charging: charge == 0x01 || charge == 0x02)
            }
        }
        let signature = PadSignature.fromRaw(face: bytes[lxIndex + 7], shoulders: b1)
        return DualSenseDecodedReport(buttons: buttons, battery: battery, signature: signature)
    }
}
