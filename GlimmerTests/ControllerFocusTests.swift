//
//  ControllerFocusTests.swift
//
//  Switch PC: the old stream is still closing when the next one takes the
//  pad. Its teardown must not park the pad under the new stream.
//

import Foundation
import Testing
@testable import Glimmer

@Suite(.serialized)
struct ControllerFocusTests {
    final class Owner {}
    final class Ran: @unchecked Sendable { var count = 0 }

    @Test func theNewestStreamHasThePad() {
        let old = Owner(), next = Owner()
        let oldID = ControllerFocus.id(old), nextID = ControllerFocus.id(next)
        let armed = Ran()
        ControllerFocus.activate(oldID) { armed.count += 1 }
        ControllerFocus.activate(nextID) { armed.count += 1 }
        #expect(armed.count == 2)
        #expect(ControllerFocus.allows(nextID))
        #expect(!ControllerFocus.allows(oldID))

        // The old stream's teardown must not park the pad under the new one.
        let parked = Ran()
        ControllerFocus.deactivate(oldID) { parked.count += 1 }
        #expect(parked.count == 0)
        ControllerFocus.deactivate(nextID) { parked.count += 1 }
        #expect(parked.count == 1)
    }
}
