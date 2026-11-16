//
//  UnfairLockTests.swift
//
//  Heap os_unfair_locks come from makeUnfairLock() only: a lock allocated in
//  one place and initialized in another shipped uninitialized once and
//  aborted the video receive thread mid-stream.
//

import Foundation
import Testing

@testable import Glimmer

struct UnfairLockTests {

    @Test func madeLocksWork() {
        let lock = makeUnfairLock()
        defer { lock.deallocate() }
        os_unfair_lock_lock(lock)
        #expect(!os_unfair_lock_trylock(lock))
        os_unfair_lock_unlock(lock)
        #expect(os_unfair_lock_trylock(lock))
        os_unfair_lock_unlock(lock)
    }

    @Test func noRawLockAllocationsInTheApp() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Glimmer")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        let offenders = try files.filter { url in
            guard url.lastPathComponent != "UnfairLock.swift" else { return false }
            return try String(contentsOf: url, encoding: .utf8).contains("os_unfair_lock_t.allocate(")
        }.map(\.lastPathComponent)
        #expect(offenders.isEmpty, "use makeUnfairLock(): \(offenders)")
    }
}
