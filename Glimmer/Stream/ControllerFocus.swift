//
//  ControllerFocus.swift
//
//  Which stream drives the controller's feedback - rumble, adaptive triggers,
//  lights, haptics, motion sampling.
//
//  One stream at a time, except across a Switch PC in Picture in Picture:
//  the next stream connects in STANDBY behind the live one (AppModel), and
//  until the cut-over the pad belongs to the game being played. A standby
//  backend's "arm the pad" work is queued (`activate`) and runs when it is
//  promoted; its feedback events are dropped meanwhile (`allows`). After the
//  cut the old stream's teardown must not park the pad under the new one
//  (`deactivate` runs only for the stream that has it).
//

import Foundation
import os

enum ControllerFocus {
    private struct State {
        var current: ObjectIdentifier?
        var standby: Set<ObjectIdentifier> = []
        var pending: [ObjectIdentifier: [@Sendable () -> Void]] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// The identity a backend is known by here.
    static func id(_ backend: AnyObject) -> ObjectIdentifier { ObjectIdentifier(backend) }

    /// The backend `id` is about to connect behind the live stream.
    static func beginStandby(_ id: ObjectIdentifier) {
        state.withLock { $0.standby.insert(id) }
    }

    /// Arm the pad for `owner`: now, or at its promotion if it is in standby.
    static func activate(_ id: ObjectIdentifier, _ body: @escaping @Sendable () -> Void) {
        let runNow = state.withLock { s -> Bool in
            if s.standby.contains(id) {
                s.pending[id, default: []].append(body)
                return false
            }
            s.current = id
            return true
        }
        if runNow { body() }
    }

    /// May `owner` drive the pad right now? False while it is in standby, and
    /// once another stream has taken the pad over.
    static func allows(_ id: ObjectIdentifier) -> Bool {
        return state.withLock { !$0.standby.contains(id) && ($0.current == nil || $0.current == id) }
    }

    /// `owner`'s teardown parks the pad - unless another stream has it now.
    static func deactivate(_ id: ObjectIdentifier, _ body: () -> Void) {
        let mine = state.withLock { s -> Bool in
            s.standby.remove(id)
            s.pending[id] = nil
            guard s.current == nil || s.current == id else { return false }
            s.current = nil
            return true
        }
        if mine { body() }
    }

    /// The cut-over: `owner` takes the pad and its queued arming runs.
    static func promote(_ id: ObjectIdentifier) {
        let queued = state.withLock { s -> [@Sendable () -> Void] in
            s.standby.remove(id)
            s.current = id
            defer { s.pending[id] = nil }
            return s.pending[id] ?? []
        }
        for body in queued { body() }
    }

    /// A standby stream that never took over (its connect failed or was
    /// cancelled): forget it.
    static func abandon(_ id: ObjectIdentifier) {
        state.withLock { s in
            s.standby.remove(id)
            s.pending[id] = nil
        }
    }
}
