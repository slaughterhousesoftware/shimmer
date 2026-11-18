//
//  ControllerFocus.swift
//
//  Which stream drives the controller's feedback - rumble, adaptive triggers,
//  lights, haptics, motion sampling. The newest stream to arm the pad has it.
//  Across a Switch PC the old stream is still closing when the next one arms
//  the pad, so the old one's teardown must not park the pad under the new
//  one (`deactivate` runs only for the stream that has it), and its late
//  feedback events are dropped (`allows`).
//

import Foundation
import os

enum ControllerFocus {
    private static let current = OSAllocatedUnfairLock<ObjectIdentifier?>(initialState: nil)

    /// The identity a backend is known by here.
    static func id(_ backend: AnyObject) -> ObjectIdentifier { ObjectIdentifier(backend) }

    /// Arm the pad for `id`, which now has it.
    static func activate(_ id: ObjectIdentifier, _ body: @escaping @Sendable () -> Void) {
        current.withLock { $0 = id }
        body()
    }

    /// May `id` drive the pad right now? False once another stream has it.
    static func allows(_ id: ObjectIdentifier) -> Bool {
        current.withLock { $0 == nil || $0 == id }
    }

    /// `id`'s teardown parks the pad - unless another stream has it now.
    static func deactivate(_ id: ObjectIdentifier, _ body: () -> Void) {
        let mine = current.withLock { owner -> Bool in
            guard owner == nil || owner == id else { return false }
            owner = nil
            return true
        }
        if mine { body() }
    }
}
