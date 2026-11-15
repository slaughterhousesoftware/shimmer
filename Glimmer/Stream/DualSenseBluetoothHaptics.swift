//
//  DualSenseBluetoothHaptics.swift
//
//  A PS5 game's haptics on a DualSense connected over Bluetooth.
//
//  Over Bluetooth the pad has no audio device; it takes haptics in HID output
//  report 0x32 instead. The format comes from Egor Vorontsov's SAxense
//  research (https://apps.sdore.me/SAxense, github.com/egormanga/SAxense):
//
//    [0]      0x32
//    [1]      tag (low nibble) / sequence (high nibble), 0
//    [2...10] packet 0x11 (0x91 = id | "sized"), length 7:
//             FE 00 00 00 00 FF <counter, +1 per report>
//    [11..76] packet 0x12 (0x92), length 64: 32 stereo frames of signed
//             8-bit PCM at 3 kHz, interleaved L/R
//    [77..137] zero
//    [138..141] CRC32 (seeded with 0xA2) of bytes 0...137, little-endian
//
//  One report every 32 frames (10.67 ms). The console's haptics are already
//  3 kHz stereo, so they go through the same jitter buffer as the USB path,
//  without resampling.
//

import Foundation
import IOKit.hid

final class DualSenseBluetoothHaptics: DualSenseHapticsOutput, @unchecked Sendable {

    static let framesPerReport = 32
    static let reportLength = 142

    /// Report 0x32 for `samples` (64 interleaved signed 8-bit values).
    static func report(samples: [Int8], counter: UInt8) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: reportLength)
        r[0] = 0x32
        let header: [UInt8] = [0x91, 7, 0xFE, 0, 0, 0, 0, 0xFF, counter, 0x92, 64]
        for (i, b) in header.enumerated() { r[2 + i] = b }
        for i in 0..<min(samples.count, 64) { r[13 + i] = UInt8(bitPattern: samples[i]) }
        let crc = DualSenseHID.bluetoothCRC(r[0..<138])
        for i in 0..<4 { r[138 + i] = UInt8((crc >> (8 * UInt32(i))) & 0xFF) }
        return r
    }

    /// Float in -1...1 to signed 8-bit.
    static func s8(_ v: Float) -> Int8 {
        Int8(max(-128, min(127, (v * 128).rounded())))
    }

    let deviceName = "DualSense (Bluetooth)"
    private let device: IOHIDDevice
    private let lock = NSLock()
    private var buffer = HapticsBuffer(outputRate: HapticsBuffer.sourceRate)
    private var timer: DispatchSourceTimer?
    private var counter: UInt8 = 0
    /// Ticks since the buffer last had something to play; reports stop after
    /// a while of silence and resume with the next effect.
    private var idleTicks = 0
    private let queue = DispatchQueue(label: "Shimmer.DualSense.bt-haptics", qos: .userInteractive)

    private init(device: IOHIDDevice) {
        self.device = device
    }

    /// Start on the open Bluetooth DualSense, or nil if there isn't one.
    static func start() -> DualSenseBluetoothHaptics? {
        guard let pad = DualSenseHID.shared.bluetoothPad() else { return nil }
        let player = DualSenseBluetoothHaptics(device: pad)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: player.queue)
        let interval = DispatchTimeInterval.nanoseconds(Int(1e9 * Double(framesPerReport) / HapticsBuffer.sourceRate))
        timer.schedule(deadline: .now(), repeating: interval, leeway: .nanoseconds(0))
        timer.setEventHandler { [weak player] in player?.tick() }
        player.timer = timer
        timer.resume()
        return player
    }

    private func tick() {
        var samples = [Int8](repeating: 0, count: 64)
        var loud = false
        lock.lock()
        buffer.render(frames: Self.framesPerReport) { i, l, r in
            samples[2 * i] = Self.s8(l)
            samples[2 * i + 1] = Self.s8(r)
            if l != 0 || r != 0 { loud = true }
        }
        idleTicks = loud || buffer.queued > 0 ? 0 : idleTicks + 1
        let send = idleTicks < 10
        lock.unlock()
        guard send else { return }
        counter &+= 1
        let bytes = Self.report(samples: samples, counter: counter)
        _ = bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x32, $0.baseAddress!, $0.count)
        }
    }

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

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }
}
