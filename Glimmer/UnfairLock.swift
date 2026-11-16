//
//  UnfairLock.swift
//
//  The one way to make a heap os_unfair_lock in Shimmer. Allocating with
//  `os_unfair_lock_t.allocate(capacity: 1)` and initializing somewhere else
//  let a lock ship uninitialized: TelemetryCounters' reorder-displacement
//  lock held malloc garbage, and the first time two threads met on it the
//  video receive thread aborted ("os_unfair_lock is corrupt") a few seconds
//  into a stream started right after another. Allocate and initialize here,
//  together; release with `deallocate()` as before.
//

import os

func makeUnfairLock() -> os_unfair_lock_t {
    let lock = os_unfair_lock_t.allocate(capacity: 1)
    lock.initialize(to: os_unfair_lock_s())
    return lock
}
