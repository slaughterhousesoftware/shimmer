//
//  DualSenseAudioHaptics.swift
//
//  A PS5 game's DualSense haptics, played on the pad's own voice coils.
//
//  Over USB a DualSense is also a 4-channel CoreAudio device: channels 1-2
//  are its speaker, 3-4 its left and right haptic actuators. The PS5 streams
//  haptics as 3 kHz stereo PCM (10 ms frames), the same waveform it would
//  send a local pad, so the console's HD haptics come through as designed
//  instead of as a rumble approximation. chiaki-ng does the same on other
//  platforms.
//
//  Frames arrive in network bursts, so they go through a jitter buffer sized
//  from the arrival jitter of the console's audio (same packets, but a
//  continuous stream). Upsampling is linear interpolation plus a low-pass that
//  removes the 3 kHz images before they reach the actuators.
//

import AVFoundation
import CoreAudio
import Foundation

// MARK: - Jitter buffer (pure, unit-tested)

/// Haptics frames come only while an effect plays, so the buffer can't tell
/// network jitter from the gap between two footsteps. It plays each run once
/// its first sample has waited `target`, and the
/// target comes from outside: the console's audio rides the same packets and
/// flows continuously, so its arrival gaps measure the jitter (ArrivalJitter).
struct HapticsBuffer {
    static let sourceRate = 3000.0

    let outputRate: Double
    private(set) var targetFrames: Int
    /// Queued audio beyond the target that we keep before dropping the oldest.
    let maxExtraFrames: Int
    var gain: Float = 1
    /// Times playback ran out of samples (the end of every effect counts), and
    /// how many of those cut a signal off mid-stroke: late frames, not an
    /// effect that ended on its own.
    private(set) var runs = 0
    private(set) var cutRuns = 0
    private(set) var playing = false

    // Ring of upsampled stereo frames.
    private var left: [Float]
    private var right: [Float]
    private var readIndex = 0
    private(set) var queued = 0

    // Upsampler: a polyphase FIR when the output is a whole multiple of 3 kHz
    // (48 kHz: x16), else linear interpolation + low-pass.
    private var polyphase: PolyphaseUpsampler?
    private let step: Double
    private var phase = 0.0
    private var previous: (Float, Float) = (0, 0)
    private var lowPassLeft: Biquad
    private var lowPassRight: Biquad
    /// Off when the output is the console's own 3 kHz (Bluetooth): no images.
    private let lowPass: Bool

    /// Rendered output frames so far, and when the waiting run's first sample came.
    private var renderedFrames = 0
    private var waitingSince: Int?
    private var tail: (Float, Float) = (0, 0)

    init(outputRate: Double, targetMs: Double = 40, extraMs: Double = 100) {
        self.outputRate = outputRate
        lowPass = outputRate > Self.sourceRate
        targetFrames = Int(targetMs / 1000 * outputRate)
        maxExtraFrames = Int(extraMs / 1000 * outputRate)
        let capacity = Int(outputRate)              // 1 s
        left = [Float](repeating: 0, count: capacity)
        right = [Float](repeating: 0, count: capacity)
        step = Self.sourceRate / outputRate
        lowPassLeft = Biquad(lowPassAt: 1200, sampleRate: outputRate)
        lowPassRight = Biquad(lowPassAt: 1200, sampleRate: outputRate)
        let factor = outputRate / Self.sourceRate
        if factor > 1, factor == factor.rounded(), factor <= 32 {
            polyphase = PolyphaseUpsampler(factor: Int(factor))
        }
    }

    mutating func setTarget(ms: Double) {
        targetFrames = Int(ms / 1000 * outputRate)
    }

    /// One frame from the console: interleaved Int16 little-endian L/R at 3 kHz.
    mutating func push(_ pcm: UnsafeRawBufferPointer) {
        if !playing, waitingSince == nil { waitingSince = renderedFrames }
        let samples = pcm.count / 4
        if var upsampler = polyphase {
            polyphase = nil                       // uniquely owned while it runs: no copy-on-write
            for i in 0..<samples {
                let l = Float(pcm.loadUnaligned(fromByteOffset: i * 4, as: Int16.self)) / 32768
                let r = Float(pcm.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self)) / 32768
                upsampler.push(l, r) { ol, or in appendRaw(ol, or) }
            }
            polyphase = upsampler
        }
        for i in 0..<(polyphase == nil ? samples : 0) {
            let l = Float(pcm.loadUnaligned(fromByteOffset: i * 4, as: Int16.self)) / 32768
            let r = Float(pcm.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self)) / 32768
            while phase < 1 {
                let t = Float(phase)
                append(previous.0 + (l - previous.0) * t, previous.1 + (r - previous.1) * t)
                phase += step
            }
            phase -= 1
            previous = (l, r)
        }
        // Latency cap: a stall followed by a flood shouldn't leave haptics late.
        if queued > targetFrames + maxExtraFrames {
            let drop = queued - targetFrames
            readIndex = (readIndex + drop) % left.count
            queued -= drop
        }
    }

    /// A frame already band-limited by the polyphase filter.
    private mutating func appendRaw(_ l: Float, _ r: Float) {
        let capacity = left.count
        if queued == capacity {
            readIndex = (readIndex + 1) % capacity
            queued -= 1
        }
        let at = (readIndex + queued) % capacity
        left[at] = l
        right[at] = r
        queued += 1
    }

    private mutating func append(_ l: Float, _ r: Float) {
        let capacity = left.count
        if queued == capacity {           // full: drop the oldest
            readIndex = (readIndex + 1) % capacity
            queued -= 1
        }
        let at = (readIndex + queued) % capacity
        left[at] = lowPass ? lowPassLeft.process(l) : l
        right[at] = lowPass ? lowPassRight.process(r) : r
        queued += 1
    }

    /// Fill `frames` output frames. Silence (with a short fade from the last
    /// value, so the coil doesn't click) while a run waits or after it ends.
    mutating func render(frames: Int, into write: (Int, Float, Float) -> Void) {
        // A waiting run starts at the sample where its first frame has waited
        // the target - by time only. The console sends haptics in bursts (2-3
        // frames every 21.3 ms), so "the target is already queued" says
        // nothing about the next burst: starting early on it ran dry ~32
        // times a minute for targets of 12-20 ms in a replay of captured
        // console streams, against ~2 by waiting.
        var startAt = frames
        if playing {
            startAt = 0
        } else if queued > 0 {
            let waited = renderedFrames - (waitingSince ?? renderedFrames)
            startAt = max(0, targetFrames - waited)
        }
        for i in 0..<frames {
            if i == startAt, !playing {
                playing = true
                waitingSince = nil
            }
            if playing, queued > 0 {
                let l = left[readIndex] * gain, r = right[readIndex] * gain
                readIndex = (readIndex + 1) % left.count
                queued -= 1
                tail = (l, r)
                write(i, l, r)
            } else {
                if playing {
                    playing = false
                    runs += 1
                    if max(abs(tail.0), abs(tail.1)) > 0.02 * max(gain, 0.001) { cutRuns += 1 }
                }
                tail = (tail.0 * 0.95, tail.1 * 0.95)
                write(i, tail.0, tail.1)
            }
        }
        renderedFrames += frames
    }
}

/// Network jitter from a continuous 10 ms stream's arrival gaps: the 95th
/// percentile of the last 500 gaps. Gaps of a quarter second or more are the
/// console pausing its audio for silence, not jitter, and are left out.
struct ArrivalJitter {
    private var gaps = [Double](repeating: 0, count: 500)
    private var next = 0
    private(set) var count = 0

    mutating func add(gapMs: Double) {
        guard gapMs < 250 else { return }
        gaps[next] = gapMs
        next = (next + 1) % gaps.count
        count = min(count + 1, gaps.count)
    }

    func percentile(_ p: Double) -> Double? {
        guard count >= 50 else { return nil }
        let sorted = gaps.prefix(count).sorted()
        return sorted[min(count - 1, Int(Double(count) * p))]
    }

    /// The haptics buffer that rides out this jitter: p95 + 5 ms, 15-100 ms.
    var hapticsTargetMs: Double? {
        percentile(0.95).map { min(100, max(15, $0 + 5)) }
    }
}

/// 3 kHz -> 3 kHz x `factor` upsampling with a polyphase FIR: a Kaiser-
/// windowed sinc low-pass at 1.5 kHz (the source's Nyquist), 12 taps per
/// phase. Replaces linear interpolation + a 1.2 kHz biquad, which together
/// lost ~5 dB at 1 kHz and ~8 dB at 1.4 kHz - the crisp top of the
/// console's haptics. Flat to ~1.1 kHz, images below -40 dB; delay 6 source
/// samples (2 ms).
struct PolyphaseUpsampler {
    static let tapsPerPhase = 12
    let factor: Int
    /// coefficients[p][k]: phase p, tap k (applied to the k-th newest input).
    private let coefficients: [[Float]]
    private var historyLeft: [Float]
    private var historyRight: [Float]
    private var head = 0

    init(factor: Int) {
        self.factor = factor
        let taps = factor * Self.tapsPerPhase
        let cutoff = 0.5 / Double(factor)            // the source Nyquist, as a fraction of the output rate
        let beta = 6.0
        func besselI0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            while term > 1e-12 * sum { term *= (x / (2 * k)) * (x / (2 * k)); sum += term; k += 1 }
            return sum
        }
        let mid = Double(taps - 1) / 2
        var prototype = [Double](repeating: 0, count: taps)
        for n in 0..<taps {
            let t = Double(n) - mid
            let sinc = t == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * t) / (.pi * t)
            let r = t / (mid + 0.5)
            let window = besselI0(beta * (1 - r * r).squareRoot()) / besselI0(beta)
            prototype[n] = sinc * window
        }
        // Each phase sums to 1: unity gain at DC, no ripple between phases.
        var phases = [[Float]](repeating: [Float](repeating: 0, count: Self.tapsPerPhase), count: factor)
        for p in 0..<factor {
            let sum = (0..<Self.tapsPerPhase).reduce(0.0) { $0 + prototype[p + $1 * factor] }
            for k in 0..<Self.tapsPerPhase { phases[p][k] = Float(prototype[p + k * factor] / sum) }
        }
        coefficients = phases
        historyLeft = [Float](repeating: 0, count: Self.tapsPerPhase)
        historyRight = [Float](repeating: 0, count: Self.tapsPerPhase)
    }

    /// One source frame in, `factor` output frames out.
    mutating func push(_ l: Float, _ r: Float, emit: (Float, Float) -> Void) {
        head = (head + Self.tapsPerPhase - 1) % Self.tapsPerPhase
        historyLeft[head] = l
        historyRight[head] = r
        for p in 0..<factor {
            var ol: Float = 0, or: Float = 0
            let c = coefficients[p]
            for k in 0..<Self.tapsPerPhase {
                let i = (head + k) % Self.tapsPerPhase
                ol += c[k] * historyLeft[i]
                or += c[k] * historyRight[i]
            }
            emit(ol, or)
        }
    }
}

/// RBJ biquad low-pass, Q = 1/√2.
struct Biquad {
    private let b0, b1, b2, a1, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(lowPassAt cutoff: Double, sampleRate: Double) {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * 0.7071)
        let cw = cos(w0), a0 = 1 + alpha
        b0 = Float((1 - cw) / 2 / a0); b1 = Float((1 - cw) / a0); b2 = b0
        a1 = Float(-2 * cw / a0); a2 = Float((1 - alpha) / a0)
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

// MARK: - Player

/// Where a PS5 stream's haptics PCM goes: the USB pad's audio channels or
/// the Bluetooth pad's haptics report.
protocol DualSenseHapticsOutput: AnyObject, Sendable {
    var deviceName: String { get }
    func push(_ pcm: UnsafeRawBufferPointer)
    func setGain(_ gain: Float)
    func setTarget(ms: Double)
    var stats: (targetMs: Int, runs: Int, cut: Int) { get }
    func stop()
}

/// Plays haptics PCM on a USB DualSense's actuator channels. `start()` returns
/// nil when no such device is present (Bluetooth pads have no audio device),
/// and the caller falls back to rumble.
final class DualSenseAudioHaptics: DualSenseHapticsOutput, @unchecked Sendable {

    /// Lock + buffer shared with the render block (which must not capture self).
    private final class Shared: @unchecked Sendable {
        let lock = os_unfair_lock_t.allocate(capacity: 1)
        var buffer: HapticsBuffer
        init(_ buffer: HapticsBuffer) {
            self.buffer = buffer
            lock.initialize(to: os_unfair_lock_s())
        }
        deinit { lock.deallocate() }
        func with<T>(_ body: (inout HapticsBuffer) -> T) -> T {
            os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
            return body(&buffer)
        }
    }

    private let engine: AVAudioEngine
    private let source: AVAudioSourceNode
    /// The format the source renders in; a restart needs the same hardware shape.
    private let format: AVAudioFormat
    private let shared: Shared
    private let onLost: @Sendable () -> Void
    /// Guards `observer`/`stopped` and serializes restarts against `stop()`.
    private let stateLock = NSLock()
    private var observer: NSObjectProtocol?
    private var stopped = false
    /// Configuration changes handled recently (restart storm guard). Main queue.
    private var recentRestarts: [Date] = []
    let deviceName: String

    private init(engine: AVAudioEngine, source: AVAudioSourceNode, format: AVAudioFormat, shared: Shared,
                 deviceName: String, onLost: @escaping @Sendable () -> Void) {
        self.engine = engine
        self.source = source
        self.format = format
        self.shared = shared
        self.deviceName = deviceName
        self.onLost = onLost
    }

    /// Open the first DualSense with 4+ output channels and start playing
    /// silence. `onLost` fires (once, on the main queue) if the device goes
    /// away or the engine can't be restarted.
    static func start(onLost: @escaping @Sendable () -> Void) -> DualSenseAudioHaptics? {
        guard let (device, name) = findDevice() else { return nil }
        let engine = AVAudioEngine()
        guard let format = bind(engine, to: device) else { return nil }
        let shared = Shared(HapticsBuffer(outputRate: format.sampleRate))
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            // No allocation on the render thread: index the buffers directly.
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let frames = Int(frameCount)
            func channel(_ i: Int) -> UnsafeMutablePointer<Float>? {
                i < buffers.count ? buffers[i].mData?.assumingMemoryBound(to: Float.self) : nil
            }
            // Everything but the actuators (the speaker on 1-2) stays silent.
            for i in 0..<buffers.count { channel(i)?.update(repeating: 0, count: frames) }
            let hapticLeft = channel(2)
            let hapticRight = channel(3)
            shared.with { buffer in
                buffer.render(frames: frames) { i, l, r in
                    hapticLeft?[i] = l
                    hapticRight?[i] = r
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.outputNode, format: format)
        do { try engine.start() } catch { return nil }
        let player = DualSenseAudioHaptics(engine: engine, source: source, format: format, shared: shared,
                                           deviceName: name, onLost: onLost)
        // The engine posts a configuration change right after it starts on the
        // pad (and again if the device's format moves): restart it then, and
        // give up only when the pad is gone.
        player.observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak player] _ in
            MainActor.assumeIsolated { player?.configurationChanged() }
        }
        return player
    }

    /// Point `engine`'s output at `device`; the 4+-channel format to render in.
    /// The pad's audio device defaults to a 512-frame I/O buffer: 10.7 ms of
    /// haptics latency before the ~2 ms the device itself adds (measured on
    /// Kevin's MacBook, 2026-11-15; the device allows 15-4096). The render
    /// work is a copy, so a 64-frame (1.3 ms) buffer costs nothing. The setting
    /// is the pad's own audio device's, which nothing else plays to.
    static let ioBufferFrames: UInt32 = 64

    private static func setSmallIOBuffer(on device: AudioDeviceID) {
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSizeRange,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &range) == noErr else { return }
        var frames = UInt32(min(range.mMaximum, max(range.mMinimum, Double(ioBufferFrames))))
        address.mSelector = kAudioDevicePropertyBufferFrameSize
        let rc = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        Diag.info("PS5: DualSense haptics I/O buffer \(frames) frames\(rc == noErr ? "" : " - refused (\(rc))")",
                  "PlayStation")
    }

    private static func bind(_ engine: AVAudioEngine, to device: AudioDeviceID) -> AVAudioFormat? {
        var device = device
        guard let unit = engine.outputNode.audioUnit,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
        else { return nil }
        setSmallIOBuffer(on: device)
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        guard hardware.channelCount >= 4, hardware.sampleRate > 0,
              let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | hardware.channelCount)
        else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channelLayout: layout)
    }

    /// The engine stopped itself. Restart it as it is: the graph is never
    /// rewired here, because AVAudioEngine reports a bad rewire by raising an
    /// Objective-C exception, which would take the app down.
    @MainActor
    private func configurationChanged() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopped else { return }
        let now = Date()
        recentRestarts = recentRestarts.filter { now.timeIntervalSince($0) < 10 } + [now]
        guard recentRestarts.count <= 5, let (device, _) = Self.findDevice(),
              Self.currentDevice(of: engine) == device || Self.bind(engine, to: device) != nil
        else {
            lost()
            return
        }
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        guard hardware.channelCount == format.channelCount, hardware.sampleRate == format.sampleRate else {
            lost()
            return
        }
        do { try engine.start() } catch { lost() }
    }

    private static func currentDevice(of engine: AVAudioEngine) -> AudioDeviceID? {
        guard let unit = engine.outputNode.audioUnit else { return nil }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, &size)
        return status == noErr ? device : nil
    }

    /// Called with `stateLock` held.
    @MainActor
    private func lost() {
        stopLocked()
        let onLost = self.onLost
        DispatchQueue.main.async { onLost() }
    }

    func push(_ pcm: UnsafeRawBufferPointer) {
        shared.with { $0.push(pcm) }
    }

    /// 0 mutes (the console's intensity set to Off).
    func setGain(_ gain: Float) {
        shared.with { $0.gain = gain }
    }

    func setTarget(ms: Double) {
        shared.with { $0.setTarget(ms: ms) }
    }

    var stats: (targetMs: Int, runs: Int, cut: Int) {
        shared.with { (Int(Double($0.targetFrames) / $0.outputRate * 1000), $0.runs, $0.cutRuns) }
    }

    /// Safe from any thread; idempotent.
    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        guard !stopped else { return }
        stopped = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
    }

    /// The first output device named like a DualSense with at least 4 channels.
    static func findDevice() -> (AudioDeviceID, String)? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return nil }
        for id in ids {
            let name = deviceName(id)
            if name.localizedCaseInsensitiveContains("DualSense"), outputChannels(id) >= 4 { return (id, name) }
        }
        return nil
    }

    private static func deviceName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return "" }
        return value as String
    }

    private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
