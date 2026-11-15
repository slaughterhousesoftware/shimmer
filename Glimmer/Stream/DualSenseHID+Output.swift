//
//  DualSenseHID+Output.swift
//
//  The DualSense OUTPUT report: building it (pure, unit-tested) and writing it.
//
//  Wire facts, measured on a USB DualSense with its own IMU (2026-11-15):
//  - IOHIDDeviceSetReport wants the report ID as the buffer's first byte
//    (hidapi does the same on macOS). Without it the pad ignores the report.
//  - valid_flag0 bit 0x02 switches the pad to rumble emulation, which turns
//    its USB-audio haptics off until a report without that bit arrives.
//    GameController's own writes (its light-bar setter, for one) set it too.
//  - Adaptive triggers apply only with valid_flag0 0x04 (right) / 0x08 (left).
//  Offsets follow SDL's DS5EffectsState_t, as chiaki-ng uses it.
//

import Foundation
import IOKit.hid

extension DualSenseHID {

    // MARK: Report building

    /// valid_flag0 bits.
    static let flagRumbleEmulation: UInt8 = 0x01
    static let flagRumbleNotHaptics: UInt8 = 0x02
    static let flagRightTrigger: UInt8 = 0x04
    static let flagLeftTrigger: UInt8 = 0x08
    /// valid_flag1 bits.
    static let flagAudioMute: UInt8 = 0x02
    static let flagLightbar: UInt8 = 0x04
    static let flagHapticsFilter: UInt8 = 0x20
    static let flagIntensity: UInt8 = 0x40

    /// The 47-byte effects state (the report data after the report ID / BT
    /// header). Triggers are always asserted so the pad holds what the host
    /// last sent. The rumble bits go in only while the host is rumbling: they
    /// mute USB-audio haptics, and a report without them stops the motors.
    static func effectsState(_ s: DualSenseOutputState) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 47)
        d[0] = flagRightTrigger | flagLeftTrigger
        if s.rumbleLeft != 0 || s.rumbleRight != 0 {
            d[0] |= flagRumbleEmulation | flagRumbleNotHaptics
            d[2] = s.rumbleRight   // high-frequency side
            d[3] = s.rumbleLeft    // low-frequency side
        }
        // The light bar only once the host chose a color: asserting it with the
        // default (0,0,0) would blank a bar GameController already lit.
        if s.lightSet {
            d[1] |= flagLightbar
            d[44] = s.lightR; d[45] = s.lightG; d[46] = s.lightB
        }
        if let intensity = s.intensity {
            d[1] |= flagIntensity
            d[36] = intensity
        }
        // Haptics on the actuators: nothing muted, full motor power (the pad
        // keeps whatever reduction its last host set - P5M measured 12.5% of
        // the signal), and the pad's haptics low-pass on, as the console does.
        if s.audioHaptics {
            d[1] |= flagAudioMute | flagHapticsFilter | flagIntensity
            d[9] = 0
            d[36] = s.intensity ?? 0
            d[39] = 0x01
        }
        for i in 0..<11 { d[10 + i] = s.rightTrigger[i] }
        for i in 0..<11 { d[21 + i] = s.leftTrigger[i] }
        return d
    }

    /// The keepalive: the haptics settings (and light bar) again, without
    /// touching the triggers or asking for rumble, so the pad plays haptics
    /// again after anyone else's write. Nil while the host rumbles - a report
    /// without the rumble bits would stop the motors.
    static func hapticsKeepAliveState(_ s: DualSenseOutputState) -> [UInt8]? {
        guard s.rumbleLeft == 0, s.rumbleRight == 0 else { return nil }
        var d = effectsState(s)
        d[0] = 0
        return d
    }

    /// The full buffer for IOHIDDeviceSetReport, report ID first.
    /// USB: 0x02 + 47 bytes. Bluetooth: 0x31, a 0x02 tag, the 47 bytes, zero
    /// padding, then a CRC32 (seeded with 0xA2) over everything before it: 78.
    static func outputReport(effects: [UInt8], bluetooth: Bool) -> (id: UInt8, bytes: [UInt8]) {
        guard bluetooth else { return (0x02, [0x02] + effects) }
        var bytes = [UInt8](repeating: 0, count: 78)
        bytes[0] = 0x31
        bytes[1] = 0x02
        for i in 0..<min(effects.count, 47) { bytes[2 + i] = effects[i] }
        let crc = bluetoothCRC(bytes[0..<74])
        for i in 0..<4 { bytes[74 + i] = UInt8((crc >> (8 * UInt32(i))) & 0xFF) }
        return (0x31, bytes)
    }

    /// IEEE CRC32 (reflected, poly 0xEDB88320) over 0xA2 then `bytes`.
    static func bluetoothCRC(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        func feed(_ byte: UInt8) {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : (crc >> 1) }
        }
        feed(0xA2)
        for b in bytes { feed(b) }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: Writing

    func writeOutputReport(to device: IOHIDDevice, bluetooth: Bool, effects: [UInt8]) {
        let (id, bytes) = Self.outputReport(effects: effects, bluetooth: bluetooth)
        let rc = bytes.withUnsafeBufferPointer { buf -> IOReturn in
            guard let base = buf.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(id), base, buf.count)
        }
        if rc == kIOReturnSuccess {
            if !loggedWriteWasSuccessful() {
                log.info("DualSense OUTPUT report write OK over \(bluetooth ? "BT" : "USB", privacy: .public)")
            }
        } else if !loggedWriteWasRefused() {
            // A refused write degrades to "no triggers / light bar from us";
            // input, buttons and battery are unaffected. Logged once.
            let hex = String(UInt32(bitPattern: rc), radix: 16)
            log.error("DualSense OUTPUT report write refused rc=0x\(hex, privacy: .public)")
        }
    }

    /// Write `effects` (nil: nothing) to every open pad. writeQueue only.
    func writeToAll(_ effects: (DualSenseOutputState) -> [UInt8]?) {
        lock.lock()
        let state = outputState
        let devices = writeDevices
        lock.unlock()
        guard let bytes = effects(state) else { return }
        for (_, entry) in devices {
            writeOutputReport(to: entry.device, bluetooth: entry.bluetooth, effects: bytes)
        }
    }

    /// Rumble through our own report (PS5 streams with USB-audio haptics,
    /// where GameController's rumble would fight the keepalive). The pad leaves
    /// rumble mode, and plays haptics again, once it drops back to zero.
    func setRumble(left: UInt8, right: UInt8) {
        lock.lock()
        outputState.rumbleLeft = left; outputState.rumbleRight = right
        lock.unlock()
        scheduleWrite()
    }

    // MARK: PS5 feedback

    /// Haptics are playing on the pad's actuators (PS5 streams). While on,
    /// every report leaves rumble emulation off and asks for full power, and a
    /// keepalive undoes any GameController write that switched that off. Over
    /// Bluetooth it waits for a pause in the haptics: each write there costs
    /// the haptics stream a slot on the link.
    func setAudioHapticsMode(_ on: Bool, keepAliveEvery seconds: Double = 1) {
        lock.lock()
        outputState.audioHaptics = on
        lock.unlock()
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.hapticsKeepAlive?.cancel()
            self.hapticsKeepAlive = nil
            guard on else { return }
            self.writeCurrentOutput()
            let timer = DispatchSource.makeTimerSource(queue: self.writeQueue)
            timer.schedule(deadline: .now() + seconds, repeating: seconds)
            timer.setEventHandler { [weak self] in
                guard let self, !self.hapticsBusy else { return }
                self.writeToAll(Self.hapticsKeepAliveState)
            }
            timer.resume()
            self.hapticsKeepAlive = timer
        }
    }

    /// The Bluetooth haptics sender calls this for every report with signal;
    /// the keepalive stays off the link until 250 ms after the last one.
    func noteHapticsActivity() {
        lock.lock(); hapticsActiveAt = DispatchTime.now().uptimeNanoseconds; lock.unlock()
    }

    var hapticsBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return DispatchTime.now().uptimeNanoseconds &- hapticsActiveAt < 250_000_000
    }

    /// Stop the keepalive now (before the manager closes).
    func cancelHapticsKeepAlive() {
        writeQueue.sync {
            hapticsKeepAlive?.cancel()
            hapticsKeepAlive = nil
        }
    }

    /// Set and write the light bar ourselves (GameController's setter would
    /// switch audio haptics off).
    func setLightbar(red: UInt8, green: UInt8, blue: UInt8) {
        setLightbarState(red: red, green: green, blue: blue)
        scheduleWrite()
    }

    /// The console's intensity settings as the pad's power-reduction byte:
    /// haptics in the low nibble (0 strong, 2 medium, 3 weak), triggers in the
    /// high nibble (0x00, 0x60, 0x90) - chiaki-ng's mapping.
    func setIntensity(haptics: UInt8, triggers: UInt8) {
        lock.lock()
        outputState.intensity = (triggers & 0xF0) | (haptics & 0x0F)
        lock.unlock()
        scheduleWrite()
    }
}
