//
//  LatencyProbe.swift
//
//  Debug-only, end to end: how long from a controller press leaving Shimmer
//  to the first decoded frame that shows it. Inert unless armed by
//  DebugAutomation (`--debug-latency=...` / `--debug-combo=...`).
//
//  The probe owns controller slot 0 while armed (a real pad's pushes are held
//  back so they can't release a test press early). It presses, then watches a
//  region of every decoded frame - e.g. Street Fighter 6's training-mode input
//  history, which draws a new row on the frame the game reads the input - and
//  stamps the first frame whose region differs from the frame before the
//  press. The same path runs for both backends (PS5 and Sunshine), from the
//  same send call to the same VideoToolbox output, so the two compare like for
//  like; what it leaves out is the display (scan-out after the decode).
//
//  Combos send a timed sequence (directions + buttons) and save frames of the
//  result, to check by eye that the game read every input.
//

import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

final class LatencyProbe: @unchecked Sendable {
    static let shared = LatencyProbe()

    /// Read on the decode and input hot paths; set once before the stream.
    nonisolated(unsafe) static var armed = false

    /// Normalized (0-1, origin top-left) region of the frame to watch.
    var region = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Floor for the frame-to-frame motion (mean |dLuma|, 0-255) that counts
    /// as the reaction; the working trigger is 3x the idle motion's p90 if higher.
    var threshold: Double = 3

    private struct State {
        var previous: [UInt8]?             // region samples of the frame before this one
        var idleMotion: [Double] = []      // recent frame-to-frame motion while not waiting
        var trigger: Double = 0            // motion that counts as the reaction, for this press
        var trace: [(ms: Double, motion: Double)]?  // per-frame motion after the press, when tracing
        var pressNanos: UInt64 = 0         // 0 = not waiting
        var detectedNanos: UInt64 = 0
        var detectedDiff: Double = 0
        var frames: UInt64 = 0
        var dumpPath: String?              // next frame goes here as PNG
        // Smoothness, over the whole run: a frame that barely differs from the
        // one before while the frames around it move is a repeated frame (the
        // host sent the same picture twice, then jumped) - visible judder.
        var lastMotions: [Double] = []     // the last three frame-to-frame motions
        var movingFrames = 0
        var repeatedFrames = 0
        var lastFrameNanos: UInt64 = 0
        var intervals: [Double] = []       // decode-output spacing, ms
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    private static let grid = 48           // samples per axis inside the region

    // MARK: Decode side (VideoToolbox output thread)

    func observe(_ image: CVImageBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard let samples = Self.sample(image, region: region) else { return }
        let threshold = self.threshold
        let dump = state.withLock { st -> String? in
            st.frames += 1
            // Frame-to-frame motion in the region. Idle animation (breathing,
            // stances) moves every frame; the reaction is the first frame that
            // moves clearly more than the idle motion just before the press.
            if st.lastFrameNanos != 0 { st.intervals.append(Double(now &- st.lastFrameNanos) / 1e6) }
            st.lastFrameNanos = now
            if let previous = st.previous, previous.count == samples.count {
                let motion = Self.meanAbsDiff(previous, samples)
                st.lastMotions.append(motion)
                if st.lastMotions.count > 3 { st.lastMotions.removeFirst() }
                if st.lastMotions.count == 3 {
                    let around = min(st.lastMotions[0], st.lastMotions[2])
                    if around >= 0.8 {
                        st.movingFrames += 1
                        if st.lastMotions[1] < 0.3 * around { st.repeatedFrames += 1 }
                    }
                }
                if st.pressNanos == 0 {
                    st.idleMotion.append(motion)
                    if st.idleMotion.count > 40 { st.idleMotion.removeFirst() }
                } else {
                    if st.detectedNanos == 0, motion >= st.trigger {
                        st.detectedNanos = now
                        st.detectedDiff = motion
                    }
                    st.trace?.append((Double(now &- st.pressNanos) / 1e6, motion))
                }
            }
            st.previous = samples
            defer { st.dumpPath = nil }
            return st.dumpPath
        }
        if let dump { Self.writePNG(image, to: dump) }
    }

    // MARK: Driver (its own task)

    /// Wait for the first decoded frames, announce the pad, then measure.
    func runLatency(backend: StreamingBackend, presses: Int, button: Int32, dumpDir: String?) async {
        guard await waitForFrames() else {
            Diag.error("LATENCY: no decoded frames - is decode running?", "Debug")
            return
        }
        announce(backend)
        if let dumpDir { await dump(to: "\(dumpDir)/latency-start.png") }
        var samples: [Double] = []
        var misses = 0
        for i in 1...presses {
            // Let the idle motion settle, then press.
            try? await Task.sleep(for: .milliseconds(Int.random(in: 700...1100)))
            let threshold = self.threshold
            let tracing = true
            state.withLock { st in
                // 3x the idle motion's median: a lively idle stance or a rare
                // blip (a gauge segment refilling) mustn't hide the reaction.
                let idle = st.idleMotion.sorted()
                let median = idle.isEmpty ? 0 : idle[idle.count / 2]
                st.trigger = max(threshold, median * 3)
                st.trace = tracing ? [] : nil
                st.detectedNanos = 0
                st.pressNanos = DispatchTime.now().uptimeNanoseconds
            }
            send(backend, buttons: button)
            try? await Task.sleep(for: .milliseconds(100))
            send(backend, buttons: 0)
            // Wait up to 400 ms more for the change (a trace keeps 600 ms).
            try? await Task.sleep(for: .milliseconds(500))
            var result: (UInt64, UInt64, Double) = (0, 0, 0)
            for _ in 0..<40 {
                result = state.withLock { ($0.pressNanos, $0.detectedNanos, $0.detectedDiff) }
                if result.1 != 0 { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            let (trace, idle, trigger) = state.withLock { st -> ([(ms: Double, motion: Double)]?, Double, Double) in
                st.pressNanos = 0
                defer { st.trace = nil }
                return (st.trace, st.idleMotion.max() ?? 0, st.trigger)
            }
            let missed = state.withLock { $0.detectedNanos == 0 }
            if let trace, i <= 3 || missed {
                let line = trace.map { String(format: "%.0f:%.1f", $0.ms, $0.motion) }.joined(separator: " ")
                Diag.notice("LATENCY trace \(i): idle max \(String(format: "%.1f", idle)) trigger \(String(format: "%.1f", trigger)) | \(line)", "Debug")
            }
            if result.1 != 0 {
                let ms = Double(result.1 &- result.0) / 1e6
                samples.append(ms)
                Diag.notice("LATENCY \(i)/\(presses): \(String(format: "%.1f", ms)) ms (motion \(String(format: "%.1f", result.2)))", "Debug")
            } else {
                misses += 1
                Diag.notice("LATENCY \(i)/\(presses): no change within 500 ms", "Debug")
            }
        }
        Diag.notice("LATENCY summary: \(Self.summary(samples)), misses \(misses)/\(presses)", "Debug")
        let (moving, repeated, intervals) = state.withLock { ($0.movingFrames, $0.repeatedFrames, $0.intervals) }
        let late = intervals.filter { $0 > 25 }.count, bunched = intervals.filter { $0 < 8 }.count
        Diag.notice("SMOOTHNESS: repeated \(repeated) of \(moving) frames in motion (\(String(format: "%.1f", moving > 0 ? 100.0 * Double(repeated) / Double(moving) : 0))%); "
            + "decode spacing: \(intervals.count) frames, >25 ms \(late), <8 ms \(bunched), \(Self.summary(intervals))", "Debug")
        if let dumpDir { await dump(to: "\(dumpDir)/latency-end.png") }
    }

    /// One step of a combo: buttons held for `ms`, then the next step.
    struct Step { var buttons: Int32; var ms: Int }

    /// Send `steps` `repeats` times, saving a frame after each run.
    func runCombo(backend: StreamingBackend, name: String, steps: [Step], repeats: Int, dumpDir: String,
                  dumpAfterMs: Int = 400) async {
        guard await waitForFrames() else { return }
        announce(backend)
        for r in 1...repeats {
            try? await Task.sleep(for: .milliseconds(1500))
            var late: [Double] = []
            var due = DispatchTime.now().uptimeNanoseconds
            for step in steps {
                // Absolute schedule: a late wake-up doesn't stretch the next step.
                let now = DispatchTime.now().uptimeNanoseconds
                if now > due { late.append(Double(now - due) / 1e6) }
                send(backend, buttons: step.buttons)
                due += UInt64(step.ms) * 1_000_000
                let wait = Int64(due) - Int64(DispatchTime.now().uptimeNanoseconds)
                if wait > 0 { try? await Task.sleep(for: .nanoseconds(wait)) }
            }
            send(backend, buttons: 0)
            try? await Task.sleep(for: .milliseconds(dumpAfterMs))
            await dump(to: "\(dumpDir)/combo-\(name)-\(r).png")
            let worst = late.max() ?? 0
            Diag.notice("COMBO \(name) \(r)/\(repeats): sent \(steps.count) steps, worst send lateness \(String(format: "%.1f", worst)) ms", "Debug")
        }
    }

    /// Send `steps` once (e.g. walk into the corner before measuring), then release.
    func runSteps(backend: StreamingBackend, steps: [Step]) async {
        guard await waitForFrames() else { return }
        announce(backend)
        for step in steps {
            send(backend, buttons: step.buttons)
            try? await Task.sleep(for: .milliseconds(step.ms))
        }
        send(backend, buttons: 0)
    }

    // MARK: Helpers

    private func announce(_ backend: StreamingBackend) {
        let all = UInt32(bitPattern: StreamProtocol.A_FLAG | StreamProtocol.B_FLAG | StreamProtocol.X_FLAG
            | StreamProtocol.Y_FLAG | StreamProtocol.UP_FLAG | StreamProtocol.DOWN_FLAG | StreamProtocol.LEFT_FLAG
            | StreamProtocol.RIGHT_FLAG | StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG | StreamProtocol.PLAY_FLAG
            | StreamProtocol.BACK_FLAG)
        _ = backend.sendControllerArrival(num: 0, mask: 1, type: UInt8(StreamProtocol.LI_CTYPE_PS),
                                          supportedButtons: all, caps: 0)
        send(backend, buttons: 0)
    }

    private func send(_ backend: StreamingBackend, buttons: Int32) {
        _ = backend.sendMultiController(num: 0, mask: 1, buttons: buttons, analog: GamepadAnalog(
            leftTrigger: 0, rightTrigger: 0, leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0))
    }

    private func waitForFrames() async -> Bool {
        for _ in 0..<300 {
            if state.withLock({ $0.frames }) > 30 { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Save the next decoded frame as a PNG (waits up to 1 s for it).
    func dump(to path: String) async {
        state.withLock { $0.dumpPath = path }
        for _ in 0..<100 {
            if state.withLock({ $0.dumpPath == nil }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    static func summary(_ ms: [Double]) -> String {
        guard !ms.isEmpty else { return "no samples" }
        let s = ms.sorted()
        func pct(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
        return String(format: "n %d min %.1f p50 %.1f p90 %.1f max %.1f ms", s.count, s[0], pct(0.5), pct(0.9), s[s.count - 1])
    }

    static func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var total = 0
        for i in 0..<min(a.count, b.count) { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(max(1, min(a.count, b.count)))
    }

    /// Luma samples on a grid inside `region` (8-bit scale), for 8/10-bit
    /// bi-planar YUV and 32BGRA buffers.
    static func sample(_ image: CVImageBuffer, region: CGRect) -> [UInt8]? {
        let format = CVPixelBufferGetPixelFormatType(image)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let planar = CVPixelBufferIsPlanar(image)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(image, 0) : CVPixelBufferGetBaseAddress(image)
        else { return nil }
        let width = planar ? CVPixelBufferGetWidthOfPlane(image, 0) : CVPixelBufferGetWidth(image)
        let height = planar ? CVPixelBufferGetHeightOfPlane(image, 0) : CVPixelBufferGetHeight(image)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(image, 0) : CVPixelBufferGetBytesPerRow(image)
        let tenBit = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange]
            .contains(format)
        let bgra = format == kCVPixelFormatType_32BGRA
        let x0 = Int(region.minX * Double(width)), y0 = Int(region.minY * Double(height))
        let w = max(1, Int(region.width * Double(width))), h = max(1, Int(region.height * Double(height)))
        var out = [UInt8]()
        out.reserveCapacity(grid * grid)
        for gy in 0..<grid {
            let y = min(height - 1, y0 + gy * h / grid)
            let row = base.advanced(by: y * stride)
            for gx in 0..<grid {
                let x = min(width - 1, x0 + gx * w / grid)
                if tenBit {
                    out.append(UInt8(row.load(fromByteOffset: x * 2, as: UInt16.self) >> 8))
                } else if bgra {
                    out.append(row.load(fromByteOffset: x * 4 + 1, as: UInt8.self))
                } else {
                    out.append(row.load(fromByteOffset: x, as: UInt8.self))
                }
            }
        }
        return out
    }

    private static func writePNG(_ image: CVImageBuffer, to path: String) {
        let ci = CIImage(cvImageBuffer: image)
        let context = CIContext()
        guard let cg = context.createCGImage(ci, from: ci.extent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }
}
