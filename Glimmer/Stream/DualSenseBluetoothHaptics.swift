//
//  DualSenseBluetoothHaptics.swift
//
//  A PS5 game's haptics on a DualSense connected over Bluetooth.
//
//  Over Bluetooth the pad has no audio device; it takes haptics in HID output
//  report 0x32. Layout (DS5Dongle's double-block form, after Egor Vorontsov's
//  SAxense research):
//
//    [0]       0x32
//    [1]       sequence << 4
//    [2...7]   packet 0x11, audio control: 0x91 04 66 <queue> <queue> <counter, +2>
//    [8...9]   packet 0x12, haptics: 0xD2 (sized, two blocks) 0x40
//    [10..137] 64 stereo frames of signed 8-bit PCM at 3 kHz, interleaved L/R
//    [138..141] CRC32 (seeded with 0xA2) of bytes 0...137, little-endian
//
//  One report per 21.33 ms. How it is sent follows P5M for Mac
//  (github.com/beecrepaldi-afk/P5M-mac, gui/src/macDualSenseBluetooth.mm):
//  a blocking IOHIDDeviceSetReport over Bluetooth waits ~16-130 ms for the
//  pad, so reports go out asynchronously from a dedicated thread with its own
//  device handle and run loop, few in flight (`maxInFlight`); silence is sent
//  for a quarter second after an effect, then nothing; when the link falls
//  behind, the oldest haptics give way. The full-power / haptics-filter
//  settings ride DualSenseHID's 0x31 report.
//  Measured on Kevin's MacBook (2026-11-15): ~33 reports/s get through at the
//  pad's default 15 ms sniff interval; GameModeBoost halves that interval.
//  PXPlay 3.2 (macOS) does the same job with one report in flight, a 32 ms
//  queue cap and a 256 ms silence tail; those numbers informed these.
//

import Foundation
import IOKit.hid

final class DualSenseBluetoothHaptics: DualSenseHapticsOutput, @unchecked Sendable {

    static let framesPerReport = 64
    static let reportLength = 142
    /// Frames of audio the pad queues before it plays. 48 (16 ms) rides out
    /// the Bluetooth link's uneven delivery; at 16 (P5M's) the pad ran dry
    /// between late reports. chiaki-ng's macOS tester found 48 felt like wired.
    static let controllerQueue: UInt8 = 48
    /// 64 frames at 3 kHz, sent 0.05% slow so the pad's own queue can't creep
    /// up between two crystals (P5M).
    static let period: UInt64 = 21_344_000
    /// Reports on the link at once. Every report queued here is one a trigger
    /// or light-bar write waits behind, and queued reports only add delay
    /// once the link is full - so one, as PXPlay (macOS) keeps, not P5M's
    /// four. With Game Mode's 7.5 ms sniff interval one carries the stream. Override: `defaults write com.kevinbpatel.shimmer
    /// DualSenseBTInFlight -int N` (1...4), for measuring.
    static let maxInFlight: Int = {
        let n = UserDefaults.standard.integer(forKey: "DualSenseBTInFlight")
        return (1...4).contains(n) ? n : 1
    }()
    /// After the signal stops, keep the pad's queue fed with silence this
    /// long, so an effect that follows a short gap starts at once instead of
    /// the pad re-priming its queue (PXPlay: 24 x 10.67 ms).
    static let silenceTailTicks = 12

    /// Report 0x32 for 128 interleaved signed 8-bit samples.
    static func report(samples: [Int8], sequence: UInt8, counter: UInt8) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: reportLength)
        r[0] = 0x32
        r[1] = (sequence & 0x0F) << 4
        let header: [UInt8] = [0x91, 4, 0x66, controllerQueue, controllerQueue, counter, 0xD2, 0x40]
        for (i, b) in header.enumerated() { r[2 + i] = b }
        for i in 0..<min(samples.count, 128) { r[10 + i] = UInt8(bitPattern: samples[i]) }
        let crc = DualSenseHID.bluetoothCRC(r[0..<138])
        for i in 0..<4 { r[138 + i] = UInt8((crc >> (8 * UInt32(i))) & 0xFF) }
        return r
    }

    /// Float in -1...1 to signed 8-bit.
    static func s8(_ v: Float) -> Int8 {
        Int8(max(-128, min(127, (v * 127).rounded())))
    }

    let deviceName = "DualSense (Bluetooth)"
    private let lock = NSLock()
    private var buffer = HapticsBuffer(outputRate: HapticsBuffer.sourceRate, extraMs: 32)
    private var thread: Thread?
    private var running = true            // `lock`
    private let opened = DispatchSemaphore(value: 0)
    private var openedOK = false

    // Sender-thread state (the run loop thread only; callbacks run there too).
    private var slots: [UnsafeMutablePointer<UInt8>] = []
    private var busy = [Bool](repeating: false, count: maxInFlight)
    private var sentAt = [UInt64](repeating: 0, count: maxInFlight)
    private var writeNanos: UInt64 = 0, writesTimed = 0
    private var sequence: UInt8 = 0
    private var counter: UInt8 = 0
    private var silentTicks = 0
    private(set) var sent = 0, skipped = 0, failed = 0, yielded = 0
    /// Writes failed in a row: the pad left Bluetooth (plugged in over USB,
    /// switched off). After `lostAfter` of them the player gives up.
    private var failedInARow = 0
    private static let lostAfter = 20
    private let onLost: () -> Void

    private init(onLost: @escaping () -> Void) { self.onLost = onLost }

    /// Start on a DualSense connected over Bluetooth, or nil if there isn't
    /// one. `onLost` runs (on main) once the pad stops taking reports.
    static func start(onLost: @escaping () -> Void) -> DualSenseBluetoothHaptics? {
        guard DualSenseHID.shared.bluetoothPad() != nil else { return nil }
        let player = DualSenseBluetoothHaptics(onLost: onLost)
        let thread = Thread { [player] in player.run() }
        thread.name = "Shimmer.DualSense.bt-haptics"
        thread.qualityOfService = .userInteractive
        player.thread = thread
        thread.start()
        _ = player.opened.wait(timeout: .now() + 2)
        guard player.openedOK else {
            player.stop()
            return nil
        }
        return player
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    // MARK: Sender thread

    private func run() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: 0x0CE6],
            [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: 0x0DF2],
        ] as CFArray)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        guard let device = devices.first(where: {
            ((IOHIDDeviceGetProperty($0, kIOHIDTransportKey as CFString) as? String) ?? "")
                .localizedCaseInsensitiveContains("bluetooth")
        }), IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            opened.signal()
            return
        }
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        slots = (0..<Self.maxInFlight).map { _ in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.reportLength)
            p.initialize(repeating: 0, count: Self.reportLength)
            return p
        }
        openedOK = true
        opened.signal()

        var next = DispatchTime.now().uptimeNanoseconds
        while isRunning {
            next += Self.period
            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < next else { break }
                // Serves the send callbacks while it waits.
                CFRunLoopRunInMode(.defaultMode, Double(next - now) / 1e9, true)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now > next + 100_000_000 { next = now }   // stalled: don't burst to catch up
            tick(device)
        }

        // Let the reports on the link finish before the buffers go.
        let giveUp = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while busy.contains(true), DispatchTime.now().uptimeNanoseconds < giveUp {
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if busy.contains(true) {
            // A callback may still come: keep its buffers and context alive.
            _ = Unmanaged.passRetained(self)
        } else {
            for p in slots { p.deallocate() }
        }
    }

    private func tick(_ device: IOHIDDevice) {
        // The link still has four reports on it: leave the haptics queued
        // (the buffer trims the oldest if this goes on).
        guard let slot = busy.firstIndex(of: false) else {
            skipped += 1
            return
        }
        // A trigger / light-bar report is waiting for the link: let it go first
        // (the haptics stay queued for the next tick).
        if DualSenseHID.shared.controlWriteWaiting {
            yielded += 1
            return
        }
        var samples = [Int8](repeating: 0, count: Self.framesPerReport * 2)
        var signal = false
        lock.lock()
        buffer.render(frames: Self.framesPerReport) { i, l, r in
            let a = Self.s8(l), b = Self.s8(r)
            samples[2 * i] = a
            samples[2 * i + 1] = b
            if a != 0 || b != 0 { signal = true }
        }
        lock.unlock()
        if signal {
            silentTicks = 0
            DualSenseHID.shared.noteHapticsActivity()
        } else {
            silentTicks += 1
            if silentTicks > Self.silenceTailTicks { return }   // after the tail, nothing
        }
        let bytes = Self.report(samples: samples, sequence: sequence, counter: counter)
        sequence = (sequence + 1) & 0x0F
        counter &+= 2
        slots[slot].update(from: bytes, count: bytes.count)
        busy[slot] = true
        sentAt[slot] = DispatchTime.now().uptimeNanoseconds
        let rc = IOHIDDeviceSetReportWithCallback(device, kIOHIDReportTypeOutput, 0x32, slots[slot], bytes.count, 1.0,
                                                  Self.sentCallback, Unmanaged.passUnretained(self).toOpaque())
        if rc != kIOReturnSuccess {
            busy[slot] = false
            noteFailure()
        } else {
            sent += 1
        }
    }

    /// Sender thread only.
    private func noteFailure() {
        failed += 1
        failedInARow += 1
        guard failedInARow == Self.lostAfter else { return }
        lock.lock(); running = false; lock.unlock()
        DispatchQueue.main.async { [onLost] in onLost() }
    }

    private static let sentCallback: IOHIDReportCallback = { context, result, _, _, _, report, _ in
        guard let context else { return }
        let me = Unmanaged<DualSenseBluetoothHaptics>.fromOpaque(context).takeUnretainedValue()
        if let i = me.slots.firstIndex(where: { $0 == report }) {
            me.busy[i] = false
            me.writeNanos &+= DispatchTime.now().uptimeNanoseconds &- me.sentAt[i]
            me.writesTimed += 1
        }
        if result != kIOReturnSuccess { me.noteFailure() } else { me.failedInARow = 0 }
    }

    // MARK: DualSenseHapticsOutput

    func push(_ pcm: UnsafeRawBufferPointer) {
        lock.lock(); defer { lock.unlock() }
        buffer.push(pcm)
    }

    func setGain(_ gain: Float) {
        lock.lock(); defer { lock.unlock() }
        buffer.gain = gain
    }

    func setTarget(ms: Double) {
        lock.lock(); defer { lock.unlock() }
        buffer.setTarget(ms: ms)
    }

    var stats: (targetMs: Int, runs: Int, cut: Int) {
        lock.lock(); defer { lock.unlock() }
        return (Int(Double(buffer.targetFrames) / buffer.outputRate * 1000), buffer.runs, buffer.cutRuns)
    }

    /// Bluetooth link counters for the session summary.
    var linkStats: String {
        let avg = writesTimed > 0 ? Double(writeNanos) / Double(writesTimed) / 1e6 : 0
        return "\(sent) reports sent, \(skipped) ticks skipped (link busy), \(yielded) yielded to trigger writes, "
            + "\(failed) failed, \(String(format: "%.1f", avg)) ms per write"
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        // The thread notices within one period and closes its handle.
    }
}
