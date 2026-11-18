import AppKit
import Carbon.HIToolbox
import Testing
@testable import Glimmer

/// Modifier keys reach the host per physical key. Tracking the modifier flag
/// alone (Shift is down / isn't) lost a key whenever left and right
/// overlapped, and the host kept it held with nothing left to release it.
struct ModifierKeyTrackerTests {
    // NSEvent.ModifierFlags raw bits: the device-independent flag, and the
    // device-dependent bit for each side.
    private let shift: UInt = 1 << 17, control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20
    private let lShift: UInt = 0x2, rShift: UInt = 0x4, lControl: UInt = 0x1, lOption: UInt = 0x20, lCommand: UInt = 0x8

    @Test func overlappingLeftAndRightShiftEachGetTheirOwnDownAndUp() {
        var tracker = ModifierKeyTracker()
        #expect(tracker.flagsChanged(keyCode: kVK_Shift, rawFlags: shift | lShift, forwardCommand: false)
            == [.down(0xA0)])
        // Right goes down while left is held: the flag doesn't change.
        #expect(tracker.flagsChanged(keyCode: kVK_RightShift, rawFlags: shift | lShift | rShift, forwardCommand: false)
            == [.down(0xA1)])
        // Left comes up while right is held: the flag still doesn't change.
        #expect(tracker.flagsChanged(keyCode: kVK_Shift, rawFlags: shift | rShift, forwardCommand: false)
            == [.up(0xA0)])
        #expect(tracker.flagsChanged(keyCode: kVK_RightShift, rawFlags: 0, forwardCommand: false)
            == [.up(0xA1)])
        #expect(tracker.held.isEmpty)
    }

    @Test func releaseAllLetsGoOfExactlyWhatTheHostHolds() {
        var tracker = ModifierKeyTracker()
        _ = tracker.flagsChanged(keyCode: kVK_RightShift, rawFlags: shift | rShift, forwardCommand: false)
        _ = tracker.flagsChanged(keyCode: kVK_Control, rawFlags: shift | rShift | control | lControl,
                                 forwardCommand: false)
        // The RIGHT shift, not a left one the host never saw go down.
        #expect(tracker.releaseAll() == [0xA1, 0xA2])
        #expect(tracker.releaseAll().isEmpty)
    }

    @Test func commandStaysOffTheWireUnlessItIsForwarded() {
        var tracker = ModifierKeyTracker()
        #expect(tracker.flagsChanged(keyCode: kVK_Command, rawFlags: command | lCommand, forwardCommand: false).isEmpty)
        #expect(tracker.flagsChanged(keyCode: kVK_Command, rawFlags: 0, forwardCommand: false).isEmpty)
        #expect(tracker.releaseAll().isEmpty)
        #expect(tracker.flagsChanged(keyCode: kVK_Command, rawFlags: command | lCommand, forwardCommand: true)
            == [.down(0x5B)])
        #expect(tracker.flagsChanged(keyCode: kVK_Command, rawFlags: 0, forwardCommand: true) == [.up(0x5B)])
    }

    /// The Mac's Caps Lock is a toggle: one event per press. Forwarded as a
    /// held level, the host toggled once per two presses.
    @Test func capsLockIsATapEveryTime() {
        var tracker = ModifierKeyTracker()
        #expect(tracker.flagsChanged(keyCode: kVK_CapsLock, rawFlags: 1 << 16, forwardCommand: false) == [.tap(0x14)])
        #expect(tracker.flagsChanged(keyCode: kVK_CapsLock, rawFlags: 0, forwardCommand: false) == [.tap(0x14)])
        #expect(tracker.held.isEmpty)
    }

    /// One event that moves two modifiers (a missed event in between) sends both.
    @Test func everyKeyThatMovedIsSent() {
        var tracker = ModifierKeyTracker()
        _ = tracker.flagsChanged(keyCode: kVK_Shift, rawFlags: shift | lShift, forwardCommand: false)
        let changes = tracker.flagsChanged(keyCode: kVK_Option, rawFlags: option | lOption, forwardCommand: false)
        #expect(Set(changes.map(String.init(describing:))) == ["up(160)", "down(164)"])
    }

    /// A synthesized event (Sticky Keys, a remote session) has no side bits:
    /// the key it names is believed, and the cleared flag releases it.
    @Test func eventsWithoutSideBitsStillPairUp() {
        var tracker = ModifierKeyTracker()
        #expect(tracker.flagsChanged(keyCode: kVK_RightControl, rawFlags: control, forwardCommand: false)
            == [.down(0xA3)])
        #expect(tracker.flagsChanged(keyCode: kVK_RightControl, rawFlags: 0, forwardCommand: false) == [.up(0xA3)])
        // No key named at all: the left one stands in.
        #expect(tracker.flagsChanged(keyCode: 0xFF, rawFlags: shift, forwardCommand: false) == [.down(0xA0)])
        #expect(tracker.flagsChanged(keyCode: 0xFF, rawFlags: 0, forwardCommand: false) == [.up(0xA0)])
    }

    /// W held, Cmd brushed, W released: the host saw W go down, so it must see
    /// it come up, whatever Cmd is doing.
    @Test func aKeyTheHostHoldsIsAlwaysReleased() {
        #expect(!InputForwarder.swallowsKeyUp(commandDown: true, captureSysKeys: false, hostHoldsKey: true))
        // A key that went down under Cmd was never forwarded: its up isn't either.
        #expect(InputForwarder.swallowsKeyUp(commandDown: true, captureSysKeys: false, hostHoldsKey: false))
        #expect(!InputForwarder.swallowsKeyUp(commandDown: false, captureSysKeys: false, hostHoldsKey: false))
        #expect(!InputForwarder.swallowsKeyUp(commandDown: true, captureSysKeys: true, hostHoldsKey: false))
    }
}
