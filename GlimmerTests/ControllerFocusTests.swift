//
//  ControllerFocusTests.swift
//
//  Switch PC in PiP: which stream drives the pad's feedback while two are up.
//

import Foundation
import Testing
@testable import Glimmer

@Suite(.serialized)
struct ControllerFocusTests {
    final class Owner {}
    final class Ran: @unchecked Sendable { var count = 0 }

    @Test func aStandbyStreamArmsThePadOnlyWhenPromoted() {
        let live = Owner(), next = Owner()
        let liveID = ControllerFocus.id(live), nextID = ControllerFocus.id(next)
        ControllerFocus.activate(liveID) {}
        ControllerFocus.beginStandby(nextID)
        let armed = Ran()
        ControllerFocus.activate(nextID) { armed.count += 1 }
        #expect(armed.count == 0)
        #expect(ControllerFocus.allows(liveID))
        #expect(!ControllerFocus.allows(nextID))

        ControllerFocus.promote(nextID)
        #expect(armed.count == 1)
        #expect(ControllerFocus.allows(nextID))
        #expect(!ControllerFocus.allows(liveID))

        // The old stream's teardown must not park the pad under the new one.
        let parked = Ran()
        ControllerFocus.deactivate(liveID) { parked.count += 1 }
        #expect(parked.count == 0)
        ControllerFocus.deactivate(nextID) { parked.count += 1 }
        #expect(parked.count == 1)
    }

    @Test func anAbandonedStandbyNeverArms() {
        let live = Owner(), next = Owner()
        let liveID = ControllerFocus.id(live), nextID = ControllerFocus.id(next)
        ControllerFocus.activate(liveID) {}
        ControllerFocus.beginStandby(nextID)
        let armed = Ran()
        ControllerFocus.activate(nextID) { armed.count += 1 }
        ControllerFocus.abandon(nextID)
        #expect(armed.count == 0)
        #expect(ControllerFocus.allows(liveID))
        let parked = Ran()
        ControllerFocus.deactivate(liveID) { parked.count += 1 }
        #expect(parked.count == 1)
    }
}
