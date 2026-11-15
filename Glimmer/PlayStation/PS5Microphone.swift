//
//  PS5Microphone.swift
//
//  Voice to the PS5: party and game chat, as the DualSense's mic does on the
//  console. The DualSense Mute button toggles it; the pad's mute light shows
//  it, lit while muted, as on the console.
//
//  libchiaki does the protocol: chiaki_opus_encoder_* encodes 10 ms of 48 kHz
//  stereo into the 40-byte Opus frames the console takes and sends them, and
//  the session's ctrl channel asks for and toggles the mic. (Its toggle's
//  argument reads backwards: true is "live".) Every session starts muted.
//
//  Source: the DualSense's own microphone when the pad is on USB (it is a
//  CoreAudio input there); over Bluetooth the pad's mic isn't reachable, so the
//  Mac's default input. Capture runs only while unmuted.
//
//  Call order and settings follow chiaki-ng's StreamSession (ToggleMute,
//  InitMic) and PXPlay 3.2's macOS client (48 kHz, 480-sample frames).
//

import AVFoundation
import CoreAudio
import Foundation

final class PS5Microphone: @unchecked Sendable {

    static let sampleRate = 48_000.0
    static let frameSamples = 480
    private static let logCategory = "PlayStation"

    private let session: UnsafeMutablePointer<ChiakiSession>
    private let encoder = UnsafeMutablePointer<ChiakiOpusEncoder>.allocate(capacity: 1)
    private let queue = DispatchQueue(label: "Shimmer.PlayStation.mic", qos: .userInteractive)

    // `queue` only.
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var pending: [Int16] = []
    private var requested = false       // the console has been asked for the mic
    private var live = false
    private var closed = false
    private var deviceName = ""

    /// Called on `queue` with the new state (true: muted).
    var onMutedChange: ((Bool) -> Void)?

    init(session: UnsafeMutablePointer<ChiakiSession>, log: UnsafeMutablePointer<ChiakiLog>) {
        self.session = session
        encoder.initialize(to: ChiakiOpusEncoder())
        chiaki_opus_encoder_init(encoder, log)
        var header = ChiakiAudioHeader()
        chiaki_audio_header_set(&header, 2, 16, UInt32(Self.sampleRate), UInt32(Self.frameSamples))
        chiaki_opus_encoder_header(&header, encoder, session)
    }

    /// Mute button: live <-> muted.
    func toggle() {
        queue.async { [self] in
            guard !closed else { return }
            if live { setLive(false) } else { unmute() }
        }
    }

    /// Stop capture; the session is going away. Blocks until done.
    func close() {
        queue.sync {
            closed = true
            stopCapture()
        }
        chiaki_opus_encoder_fini(encoder)
        encoder.deinitialize(count: 1)
        encoder.deallocate()
    }

    // MARK: queue

    private func unmute() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard granted else {
                    Diag.notice("PS5: microphone access denied - chat stays muted", Self.logCategory)
                    return
                }
                self?.queue.async { self?.unmute() }
            }
            return
        default:
            Diag.notice("PS5: microphone access is off for Shimmer (System Settings > Privacy & Security "
                + "> Microphone) - chat stays muted", Self.logCategory)
            return
        }
        guard startCapture() else { return }
        if !requested {
            chiaki_session_connect_microphone(session)
            requested = true
        }
        setLive(true)
    }

    private func setLive(_ on: Bool) {
        live = on
        chiaki_session_toggle_microphone(session, on)   // libchiaki: true = live
        if !on { stopCapture() }
        Diag.notice("PS5: microphone \(on ? "live (\(deviceName))" : "muted")", Self.logCategory)
        onMutedChange?(!on)
    }

    private func startCapture() -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let pad = Self.dualSenseInput(), let unit = input.audioUnit {
            var id = pad
            let rc = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            deviceName = rc == noErr ? "DualSense" : "default input"
        } else {
            deviceName = "default input"
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                       channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: mono) else {
            Diag.error("PS5: no usable microphone input", Self.logCategory)
            return false
        }
        self.converter = converter
        pending.removeAll(keepingCapacity: true)
        input.installTap(onBus: 0, bufferSize: 512, format: inFormat) { [weak self] buffer, _ in
            self?.convert(buffer, to: mono)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Diag.error("PS5: microphone failed to start: \(error.localizedDescription)", Self.logCategory)
            return false
        }
        self.engine = engine
        return true
    }

    private func stopCapture() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        converter = nil
    }

    /// Audio thread: resample to 48 kHz mono, then hand 16-bit stereo to `queue`.
    private func convert(_ buffer: AVAudioPCMBuffer, to mono: AVAudioFormat) {
        guard let converter else { return }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let samples = out.floatChannelData?[0], out.frameLength > 0 else { return }
        var stereo = [Int16](repeating: 0, count: Int(out.frameLength) * 2)
        for i in 0..<Int(out.frameLength) {
            let v = Int16(max(-1, min(1, samples[i])) * 32767)
            stereo[2 * i] = v
            stereo[2 * i + 1] = v
        }
        queue.async { [weak self] in self?.encode(stereo) }
    }

    private func encode(_ stereo: [Int16]) {
        guard live, !closed else { return }
        pending += stereo
        let frame = Self.frameSamples * 2
        while pending.count >= frame {
            pending.withUnsafeMutableBufferPointer { buf in
                chiaki_opus_encoder_frame(buf.baseAddress, encoder)
            }
            pending.removeFirst(frame)
        }
    }

    /// The DualSense's microphone, when it is a CoreAudio input (USB).
    static func dualSenseInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return nil }
        return ids.first { id in
            guard inputChannels(id) > 0 else { return false }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
                  let value = name?.takeRetainedValue() as String? else { return false }
            return value.localizedCaseInsensitiveContains("DualSense")
        }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
