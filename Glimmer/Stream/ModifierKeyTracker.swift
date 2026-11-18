//
//  ModifierKeyTracker.swift
//
//  Which modifier KEYS the host believes are down, kept per physical key
//  (left and right apart) rather than per modifier.
//
//  macOS reports modifiers as one flag each: Shift is down or it isn't. The
//  host's keyboard has two Shift keys, and the stream forwards them as
//  VK_LSHIFT and VK_RSHIFT. Diffing the flag alone loses a key whenever the
//  two overlap: left down, right down (flag unchanged: nothing sent), left up
//  (flag unchanged: nothing sent), right up (flag clears: RIGHT up sent). The
//  host then held left Shift with nothing left to release it, since the
//  bookkeeping said no modifier was down.
//
//  Each flagsChanged event names the key that moved (its keyCode) and carries
//  the device-dependent bits that say which side is down; those are what this
//  reads. Caps Lock is a toggle on the Mac - one event per press, the flag
//  flipping each time - so it is forwarded as a tap, not as a held level.
//
//  Pure value type: the forwarder sends what it returns (ModifierKeyTrackerTests).
//

import AppKit
import Carbon.HIToolbox

struct ModifierKeyTracker {
    enum Change: Equatable {
        case down(Int16)
        case up(Int16)
        /// Down and straight back up (Caps Lock).
        case tap(Int16)
    }

    struct Key {
        let keyCode: Int
        /// The Windows virtual-key code the host is sent.
        let vk: Int16
        /// The device-dependent bit of NSEvent.modifierFlags for this side
        /// (IOKit's NX_DEVICE*KEYMASK).
        let deviceMask: UInt
        let flag: NSEvent.ModifierFlags
    }

    static let capsLockVK: Int16 = 0x14

    static let keys: [Key] = [
        Key(keyCode: kVK_Control, vk: 0xA2, deviceMask: 0x0000_0001, flag: .control),       // VK_LCONTROL
        Key(keyCode: kVK_RightControl, vk: 0xA3, deviceMask: 0x0000_2000, flag: .control),  // VK_RCONTROL
        Key(keyCode: kVK_Shift, vk: 0xA0, deviceMask: 0x0000_0002, flag: .shift),           // VK_LSHIFT
        Key(keyCode: kVK_RightShift, vk: 0xA1, deviceMask: 0x0000_0004, flag: .shift),      // VK_RSHIFT
        Key(keyCode: kVK_Option, vk: 0xA4, deviceMask: 0x0000_0020, flag: .option),         // VK_LMENU
        Key(keyCode: kVK_RightOption, vk: 0xA5, deviceMask: 0x0000_0040, flag: .option),    // VK_RMENU
        Key(keyCode: kVK_Command, vk: 0x5B, deviceMask: 0x0000_0008, flag: .command),       // VK_LWIN
        Key(keyCode: kVK_RightCommand, vk: 0x5C, deviceMask: 0x0000_0010, flag: .command),  // VK_RWIN
    ]

    /// The modifier keys the host holds, by virtual-key code.
    private(set) var held: Set<Int16> = []

    /// One flagsChanged event → what to send. `forwardCommand` false keeps
    /// the Command keys off the wire entirely (the host would open its Start
    /// menu on the key-up).
    mutating func flagsChanged(keyCode: Int, rawFlags: UInt, forwardCommand: Bool) -> [Change] {
        if keyCode == kVK_CapsLock { return [.tap(Self.capsLockVK)] }
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
        var changes: [Change] = []
        let named = Self.keys.first { $0.keyCode == keyCode }
        for key in Self.keys {
            if key.flag == .command, !forwardCommand { continue }
            guard let down = Self.isDown(key, named: named, rawFlags: rawFlags, flags: flags, held: held) else {
                continue
            }
            if down, !held.contains(key.vk) {
                held.insert(key.vk)
                changes.append(.down(key.vk))
            } else if !down, held.contains(key.vk) {
                held.remove(key.vk)
                changes.append(.up(key.vk))
            }
        }
        return changes
    }

    /// Is `key` down after this event? nil when the event doesn't say.
    private static func isDown(_ key: Key, named: Key?, rawFlags: UInt, flags: NSEvent.ModifierFlags,
                               held: Set<Int16>) -> Bool? {
        // The modifier's flag is clear: neither side is down.
        guard flags.contains(key.flag) else { return false }
        let sides = keys.filter { $0.flag == key.flag }
        let sideBits = sides.reduce(UInt(0)) { $0 | $1.deviceMask }
        // A real keyboard event says which side(s) are down.
        if rawFlags & sideBits != 0 { return rawFlags & key.deviceMask != 0 }
        // No side bits (a synthesized event - Sticky Keys, a remote session):
        // the flag is set, so something of this modifier is down. Believe the
        // key the event names; with no name, the left one stands in, unless a
        // side is already held.
        if let named { return named.flag == key.flag ? (named.keyCode == key.keyCode || held.contains(key.vk)) : nil }
        if sides.contains(where: { held.contains($0.vk) }) { return held.contains(key.vk) }
        return key.keyCode == sides.first?.keyCode
    }

    /// Everything held, to be released (focus lost, the stream ending); the
    /// tracker then holds nothing.
    mutating func releaseAll() -> [Int16] {
        let all = held.sorted()
        held.removeAll()
        return all
    }
}
