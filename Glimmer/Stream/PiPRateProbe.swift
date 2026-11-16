//
//  PiPRateProbe.swift
//
//  What the Picture in Picture window really shows, measured: frames handed
//  to its layer (and refused - renderer not ready, or failed), and how many
//  NEW pictures the layer actually displayed, sampled at 240 Hz. One log line
//  every 2 s while PiP is up. Debugging aid, off unless asked for:
//  `--debug-pip-rate` or `defaults write com.kevinbpatel.shimmer debugPiPRate -bool true`.
//

import AVFoundation
import os

enum PiPRateProbe {
    struct Counts { var enqueued = 0, notReady = 0, failed = 0 }

    static let enabled: Bool = ProcessInfo.processInfo.arguments.contains("--debug-pip-rate")
        || UserDefaults.standard.bool(forKey: "debugPiPRate")

    private static let counts = OSAllocatedUnfairLock(initialState: Counts())

    enum Field: Sendable { case enqueued, notReady, failed }

    static func count(_ field: Field) {
        guard enabled else { return }
        counts.withLock { c in
            switch field {
            case .enqueued: c.enqueued += 1
            case .notReady: c.notReady += 1
            case .failed: c.failed += 1
            }
        }
    }

    static func take() -> Counts {
        counts.withLock { c in defer { c = Counts() }; return c }
    }
}

/// Samples the PiP layer's displayed picture on the main thread while PiP is up.
@MainActor
final class PiPRateSampler {
    private var timer: Timer?
    private var lastHash: UInt64 = 0
    private var shown = 0
    private var samples = 0
    private var windowStart = Date()
    private weak var layer: AVSampleBufferDisplayLayer?

    func start(layer: AVSampleBufferDisplayLayer) {
        guard PiPRateProbe.enabled, timer == nil else { return }
        self.layer = layer
        windowStart = Date()
        _ = PiPRateProbe.take()
        let t = Timer(timeInterval: 1.0 / 240, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastHash = 0
    }

    /// 256 luma samples across the picture, FNV-hashed.
    private static func hash(_ buffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
        else { return 0 }
        let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var h: UInt64 = 0xcbf29ce484222325
        for gy in 0..<16 { for gx in 0..<16 {
            let offset = (height * (2 * gy + 1) / 32) * rowBytes + (rowBytes * (2 * gx + 1) / 32)
            h = (h ^ UInt64(bytes[offset])) &* 0x100000001b3
        } }
        _ = width
        return h
    }

    private func tick() {
        guard let layer else { return }
        samples += 1
        // The renderer hands back a fresh copy each call: compare pixels.
        if let buffer = layer.sampleBufferRenderer.displayedPixelBuffer() {
            let hash = Self.hash(buffer)
            if hash != lastHash { shown += 1 }
            lastHash = hash
        }
        let elapsed = Date().timeIntervalSince(windowStart)
        guard elapsed >= 2 else { return }
        let c = PiPRateProbe.take()
        let line = String(format: "PiP rate: shown %.1f fps, enqueued %.1f/s, refused not-ready %.1f/s, failed %d (%d samples)",
                          Double(shown) / elapsed, Double(c.enqueued) / elapsed, Double(c.notReady) / elapsed,
                          c.failed, samples)
        Diag.info("\(line, privacy: .public)", "Stream.PiP")
        shown = 0
        samples = 0
        windowStart = Date()
    }
}
