//
//  DualSenseHID.swift
//
//  Raw-HID side-channel for the Sony DualSense, read over IOKit's
//  IOHIDManager - exactly how moonlight-qt / SDL's HIDAPI driver does it.
//  macOS's GameController framework does NOT deliver the DualSense's centre
//  buttons (Options ≡, Create/Share, Mute) to apps, so a controller-only exit
//  chord and full button parity are impossible through GCController alone.
//  This reads the raw input report alongside GameController (non-exclusive
//  open - it never seizes the device, so GCController keeps everything it
//  already provides: sticks, face, shoulders, triggers, touchpad, battery).
//
//  Surfaces the centre buttons GameController drops (plus the two shoulder bits
//  the quit-chord predicate reads from the same byte). Everything else stays
//  on the GameController path.
//
//  REQUIRES the "Input Monitoring" privacy permission (TCC kTCCServiceListenEvent
//  - it covers game controllers, not just keyboards). Raw-HID open works under
//  the unsandboxed Developer-ID build with no device.* entitlement. NOT
//  Mac-App-Store-compatible (raw device HID is a hard App-Review reject).
//  MAS-STRIP: a future Mac App Store target must remove this file and the call
//  sites that reference DualSenseHID (ControllerForwarder / InputForwarder /
//  TroubleshootingPane).
//

import Foundation
import IOKit.hid
import os.log

/// The DualSense buttons GameController doesn't expose, mapped to the host's
/// button semantics by `ControllerForwarder`, plus the two shoulder bits from
/// the same report byte. The shoulders are NOT forwarded from here (GameController
/// stays the host's source for L1/R1); they exist so the quit-chord predicate
/// can read every button of "Start + Select + L1 + R1" from ONE coherent report
/// instead of splicing raw-HID centre bits onto GameController's view of the
/// shoulders - the two sources disagree in time, and GameController withholds
/// input around a bound system gesture (Create is bound on macOS 26).
struct DualSenseExtraButtons: Equatable, Sendable {
    var options = false    // ≡  → Start  (PLAY_FLAG)
    var create = false     // Share/Create → Back/Select (BACK_FLAG)
    var ps = false         // PS → Guide  (SPECIAL_FLAG)
    var mute = false       // Mic mute → MISC_FLAG
    var l1 = false         // chord-only; host L1 rides GameController
    var r1 = false         // chord-only; host R1 rides GameController
}

/// Battery decoded straight from the DualSense report. We read this ourselves
/// because opening the pad over raw HID makes `gamecontrollerd` drop the
/// enhanced-report battery field, so `GCController.battery` goes nil while the
/// HID reader is live (confirmed via SDL/Linux hid-playstation). Callers prefer
/// this whenever `DualSenseHID` is running.
struct DualSenseBattery: Equatable, Sendable {
    var percent: Int       // 0...100
    var charging: Bool
}

/// The merged state we write into the DualSense OUTPUT report (0x02 USB / 0x31
/// BT). All three families (rumble, lightbar, adaptive triggers) share one
/// report, so we keep the latest of each and re-emit the whole thing on any
/// update. Trigger blocks are the DualSense-native MODE byte + 10 param bytes
/// (the Sunshine wire passes these through verbatim). Defaults are the neutral
/// state: motors off, lightbar off, triggers off (mode 0x00 = no effect).
struct DualSenseOutputState: Equatable, Sendable {
    var rumbleLeft: UInt8 = 0   // low-freq / heavy motor
    var rumbleRight: UInt8 = 0  // high-freq / light motor
    var lightR: UInt8 = 0
    var lightG: UInt8 = 0
    var lightB: UInt8 = 0
    /// True once the host has sent a lightbar color this session. Until then we
    /// must NOT assert LIGHTBAR_CONTROL_ENABLE in an output write - doing so
    /// with the default (0,0,0) would blank a bar that gamecontrollerd/Sunshine
    /// already lit (the pre-first-color window an adaptive-trigger write hits).
    var lightSet: Bool = false
    /// 11 bytes each: [mode][10 params]. 0x00 mode = trigger off (neutral).
    var leftTrigger: [UInt8] = [UInt8](repeating: 0, count: 11)
    var rightTrigger: [UInt8] = [UInt8](repeating: 0, count: 11)
    /// The console's haptics/trigger strength (PS5 "Vibration Intensity" and
    /// "Trigger Effect Intensity"): byte 36 of the effects state, low nibble
    /// haptics/rumble reduction, high nibble trigger reduction. nil = untouched.
    var intensity: UInt8?
    /// True while haptics play through the pad's USB audio device. The report
    /// must then never set the "rumble instead of haptics" bit.
    var audioHaptics = false
    /// The pad's own haptics low-pass (byte 39) while `audioHaptics`. Off on
    /// USB, as Sony's Remote Play app leaves it: our upsampler already band-
    /// limits at the source's 1.5 kHz, so the pad's filter only dulls crisp
    /// effects. On for Bluetooth, where the pad gets the raw 3 kHz stream.
    var hapticsFilter = true
    /// USB with audio haptics: rumble goes out without the "rumble instead of
    /// haptics" bit, plus enable byte 38 bit 0x08, as Sony's Remote Play does
    /// on current pad firmware - the motors run and the haptics keep playing.
    var rumbleKeepsHaptics = false
    /// The mic mute light (PS5 chat): true lit (muted), false off, nil untouched.
    var micLED: Bool?
}

/// Reference-counted singleton owning one IOHIDManager for the DualSense raw
/// report. Both the live stream (InputForwarder) and the Troubleshooting input
/// test `retain()` it; it opens on the first retain and closes on the last
/// release. Single-pad assumption: the decoded button state applies to the
/// DualSense the user is holding (a Moonlight client streams one pad).
final class DualSenseHID: @unchecked Sendable {
    static let shared = DualSenseHID()

    let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "DualSenseHID")
    /// Replaced when an open fails: a manager whose connection to the HID
    /// service went bad (open rc 0x10000003, then 0xe00002c2 on every later
    /// open - seen on the MacBook 2026-11-16) never recovers, which left every
    /// stream after it with no trigger effects and no Bluetooth haptics.
    private var manager: IOHIDManager
    let lock = NSLock()

    // All mutable state below is guarded by `lock`.
    /// Each pad's latest decoded centre buttons and GameController-visible
    /// button set, by device (the same key as `writeDevices`). Kept per pad:
    /// with two players one shared value flipped between the pads' reports
    /// (each ~250/s), so a held Options flickered and reached both slots.
    private var padInputs: [UnsafeMutableRawPointer: (extras: DualSenseExtraButtons, signature: UInt32, axes: DualSenseRawAxes?)] = [:]
    /// Which physical pad each GameController slot is, once button presses
    /// have tied them together (noteGameControllerState).
    private var slotDevices: [UInt8: UnsafeMutableRawPointer] = [:]
    /// Evidence toward a binding: the pad a slot's last matches pointed at
    /// and how many times in a row.
    private var bindVotes: [UInt8: (device: UnsafeMutableRawPointer, count: Int)] = [:]
    private var retainCount = 0
    private var running = false
    // Per-device input-report buffers. A buffer handed to IOKit is NEVER
    // freed: the device's port keeps copying reports into it after
    // IOHIDManagerClose and after the callback is cleared (a report already
    // queued on the run loop still lands - AddressSanitizer caught 78-byte
    // Bluetooth reports written into a freed buffer right after a stream
    // stopped, corrupting whatever the allocator had reused it for, which is
    // what crashed SwiftUI 1-2 s after ending or starting a stream). Each pad
    // gets one 128-byte buffer for the life of the process, reused when it
    // matches again; the device is retained with it, so its pointer - the
    // key - can't be taken by another device.
    private var reportBuffers: [UnsafeMutableRawPointer: (device: IOHIDDevice, buffer: UnsafeMutablePointer<UInt8>)] = [:]
    private let bufLen = 128 // ≥ 78 (BT) / 64 (USB)

    // Matched devices, kept so the OUTPUT-report write path (adaptive triggers)
    // can address them. Retained (a +1 from IOHIDManager's matching set isn't
    // guaranteed to outlive a callback), keyed by the same opaque pointer as
    // `reportBuffers`. Bluetooth devices need report ID 0x31 + a trailing CRC32;
    // USB uses 0x02 with no CRC, so we cache each device's transport at match.
    var writeDevices: [UnsafeMutableRawPointer: (device: IOHIDDevice, bluetooth: Bool)] = [:]
    /// Merged DualSense OUTPUT state. The 0x02/0x31 report carries lightbar +
    /// rumble + both trigger blocks together (all-or-nothing), so a trigger
    /// write MUST re-send the current lightbar + rumble or it would clobber
    /// them to zero. ControllerHaptics feeds lightbar/rumble here when raw-HID
    /// is live; setAdaptiveTriggers feeds the trigger blocks. Lock-guarded.
    var outputState = DualSenseOutputState()
    /// Each pad's own OUTPUT state, by device. Rumble, light bar and triggers
    /// for one player go to that player's pad only (`targets(forSlot:)`);
    /// settings for every pad (console intensity, audio haptics, mic light)
    /// change `outputState` and every pad alike. A pad that connects starts
    /// from `outputState`.
    var padOutputs: [UnsafeMutableRawPointer: DualSenseOutputState] = [:]
    /// Per pad, which trigger blocks changed since they were last written
    /// (valid_flag0 bits: right 0x04, left 0x08).
    var padDirtyTriggers: [UnsafeMutableRawPointer: UInt8] = [:]
    /// What each slot last asked of its pad (triggers, light bar, settings),
    /// kept across the pad dropping off: a pad that comes back - USB to
    /// Bluetooth and back, asleep and awake - gets it again when it is tied
    /// to its slot, rather than sitting blank until the game sends a new effect.
    var slotOutputs: [UInt8: DualSenseOutputState] = [:]
    /// Latch so the "SetReport refused" breadcrumb logs once, not per write
    /// (host re-arms triggers can arrive at frame rate).
    private var loggedWriteFailure = false
    /// Latch for the first successful OUTPUT write (proves the raw-HID write
    /// path reached the device).
    private var loggedWriteSuccess = false
    /// Re-asserts audio-haptics mode while a PS5 stream plays haptics through
    /// the pad's USB audio device (see DualSenseHID+Output.swift). writeQueue only.
    var hapticsKeepAlive: DispatchSourceTimer?
    /// Last Bluetooth haptics report with signal (uptime ns, `lock`).
    var hapticsActiveAt: UInt64 = 0
    /// Write coalescing (`lock`): a write is queued; when the last one was
    /// requested and when one last finished (uptime ns).
    var writePending = false
    var writeRequestedAt: UInt64 = 0
    var controlWriteDone: UInt64 = 0

    /// Serial queue for the IOKit OUTPUT-report writes. The host feedback
    /// callbacks fire on the enet receive thread; we hop here so a SetReport
    /// (which can block briefly) never stalls the control channel's ACK path,
    /// the same off-thread discipline ControllerHaptics uses for rumble.
    let writeQueue = DispatchQueue(label: "io.ugfugl.Glimmer.dualsense-hid-write",
                                           qos: .userInitiated)

    /// Called on the main queue whenever the decoded buttons change - lets the
    /// input-test UI refresh. Set by the consumer; cleared on the last release.
    var onChange: (@MainActor () -> Void)?
    /// Called on the main queue when a tied pad's raw sticks or triggers
    /// change, with its slot: a movement inside GameController's deadzone
    /// fires no GameController handler, so this is what carries it.
    var onAxesChange: (@MainActor (UInt8) -> Void)?
    /// Called on the main thread after the reader reconnected its pads (a
    /// rebuild): the PS5 path looks for a haptics output again.
    var onDevicesChanged: (() -> Void)?

    /// Total raw input reports received since the manager opened - a live
    /// "is the device delivering anything?" signal for the input test. Zero
    /// while Input Monitoring is denied.
    private var reportCountLocked = 0
    var reportCount: Int {
        lock.lock(); defer { lock.unlock() }
        return reportCountLocked
    }

    /// Battery decoded from the HID status byte; nil until a report with a
    /// valid battery field arrives (the simple 10-byte BT report has none).
    private var batteryLocked: DualSenseBattery?
    var battery: DualSenseBattery? {
        lock.lock(); defer { lock.unlock() }
        return batteryLocked
    }

    /// Every pad's centre buttons together (thread-safe snapshot): the input
    /// test and the Settings chord capture, which don't know a slot.
    var buttons: DualSenseExtraButtons {
        lock.lock(); defer { lock.unlock() }
        return Self.merged(padInputs.values.map(\.extras))
    }

    /// The centre buttons of the pad that is `slot`. Until a press has tied the
    /// slot to a pad: the only pad, or every pad no other slot has claimed.
    func buttons(forSlot slot: UInt8) -> DualSenseExtraButtons {
        lock.lock(); defer { lock.unlock() }
        if let key = slotDevices[slot], let pad = padInputs[key] { return pad.extras }
        let claimed = Set(slotDevices.filter { $0.key != slot }.map(\.value))
        return Self.merged(padInputs.filter { !claimed.contains($0.key) }.map(\.value.extras))
    }

    /// The USB location of the pad that is `slot` (nil: not tied yet, or not
    /// on USB) - names its audio device for haptics.
    func usbLocation(forSlot slot: UInt8) -> UInt32? {
        lock.lock(); defer { lock.unlock() }
        guard let key = slotDevices[slot], let entry = writeDevices[key], !entry.bluetooth else { return nil }
        return (IOHIDDeviceGetProperty(entry.device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint32Value
    }

    /// The raw sticks and triggers of the pad that is `slot` (nil until a press
    /// has tied them, or while the pad sends no full report).
    func axes(forSlot slot: UInt8) -> DualSenseRawAxes? {
        lock.lock(); defer { lock.unlock() }
        guard let key = slotDevices[slot] else { return nil }
        return padInputs[key]?.axes
    }

    /// The physical pad bound to `slot`, if a press has tied them.
    func device(forSlot slot: UInt8) -> UnsafeMutableRawPointer? {
        lock.lock(); defer { lock.unlock() }
        return slotDevices[slot]
    }

    static func merged(_ all: [DualSenseExtraButtons]) -> DualSenseExtraButtons {
        var m = DualSenseExtraButtons()
        for b in all {
            m.options = m.options || b.options; m.create = m.create || b.create
            m.ps = m.ps || b.ps; m.mute = m.mute || b.mute
            m.l1 = m.l1 || b.l1; m.r1 = m.r1 || b.r1
        }
        return m
    }

    /// GameController's view of `slot` (its `PadSignature`): tie the slot to
    /// the one pad whose raw report shows the same buttons. Two matches in a
    /// row bind (or re-bind); an empty set or a set two pads share proves
    /// nothing. With a single pad there is nothing to tell apart.
    func noteGameControllerState(slot: UInt8, signature: UInt32) {
        lock.lock()
        let restored = noteGameControllerStateLocked(slot: slot, signature: signature)
        lock.unlock()
        if restored { scheduleWrite() }
    }

    private func noteGameControllerStateLocked(slot: UInt8, signature: UInt32) -> Bool {
        if padInputs.count == 1, let only = padInputs.keys.first {
            if slotDevices[slot] != only { return bind(slot: slot, to: only) }
            return false
        }
        guard signature != 0 else { return false }
        if let bound = slotDevices[slot], padInputs[bound]?.signature == signature { return false }
        let matches = padInputs.filter { $0.value.signature == signature }.map(\.key)
        guard matches.count == 1, let device = matches.first else { return false }
        let votes = bindVotes[slot].map { $0.device == device ? $0.count + 1 : 1 } ?? 1
        bindVotes[slot] = (device, votes)
        return votes >= 2 ? bind(slot: slot, to: device) : false
    }

    /// Returns true when the pad got its slot's last output and needs a write.
    @discardableResult
    private func bind(slot: UInt8, to device: UnsafeMutableRawPointer) -> Bool {
        for (other, key) in slotDevices where key == device && other != slot { slotDevices[other] = nil }
        slotDevices[slot] = device
        bindVotes[slot] = nil
        var restored = false
        if var state = slotOutputs[slot] {
            // Motors stay off: a rumble from before the pad dropped is stale.
            state.rumbleLeft = 0; state.rumbleRight = 0
            padOutputs[device] = state
            padDirtyTriggers[device] = Self.bothTriggers
            restored = true
        }
        let transport = writeDevices[device].map { $0.bluetooth ? "Bluetooth" : "USB" } ?? "?"
        Diag.notice("DualSense on slot \(slot) is the \(transport) pad #\(deviceOrdinal(device))"
            + (restored ? " (its triggers and light restored)" : ""), "Controller")
        return restored
    }

    /// A stable small number for a pad in the logs.
    private func deviceOrdinal(_ device: UnsafeMutableRawPointer) -> Int {
        reportBuffers.keys.sorted { UInt(bitPattern: $0) < UInt(bitPattern: $1) }.firstIndex(of: device) ?? -1
    }

    /// The slot's controller detached: forget which pad it was.
    func forgetSlot(_ slot: UInt8) {
        lock.lock(); defer { lock.unlock() }
        slotDevices[slot] = nil
        bindVotes[slot] = nil
    }

    /// True while the IOHIDManager is open (someone holds a `retain()`). The
    /// battery uplink reads this to decide whether to trust the raw-HID battery
    /// decode (which only fills while the reader is live) over GCController's
    /// (which goes .unknown for a DualSense in enhanced-report mode).
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private init() {
        manager = Self.makeManager()
    }

    private static func makeManager() -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Sony vendor 0x054C, DualSense (0x0CE6) + DualSense Edge (0x0DF2).
        let matches: [[String: Any]] = [
            [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: 0x0CE6],
            [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: 0x0DF2]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        return manager
    }

    /// Hook `manager` up and open it (main thread). On failure: a fresh
    /// manager, once.
    private func openManager() -> IOReturn {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        func attempt() -> IOReturn {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatched, ctx)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemoved, ctx)
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        let rc = attempt()
        guard rc != kIOReturnSuccess else { return rc }
        Diag.notice("DualSense HID open rc=0x\(String(UInt32(bitPattern: rc), radix: 16)) - trying a new HID manager", "Controller")
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = Self.makeManager()
        return attempt()
    }

    /// Opt-in gate (mirrors AppModel.rawHIDControllerEnabled). Read
    /// from non-UI code (ControllerForwarder) so the raw-HID reader - and its
    /// Input Monitoring prompt - only ever engage when the user has turned the
    /// feature on in Settings.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "rawHIDControllerEnabled") }

    // MARK: Input Monitoring permission

    /// Current Input Monitoring access without prompting.
    static var accessGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
    static var accessDenied: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied
    }

    /// Present the Input Monitoring prompt if the state is still unknown.
    /// Returns true if already/now granted.
    @discardableResult
    static func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: Lifecycle (ref-counted)

    func retain() {
        lock.lock()
        retainCount += 1
        let shouldStart = retainCount == 1 && !running
        if shouldStart { running = true }
        lock.unlock()
        if shouldStart { start() }
    }

    func release() {
        lock.lock()
        retainCount = max(0, retainCount - 1)
        let shouldStop = retainCount == 0 && running
        if shouldStop { running = false }
        lock.unlock()
        if shouldStop { stop() }
    }

    private func start() {
        // NOTE: we deliberately do NOT call IOHIDRequestAccess() here - it
        // BLOCKS the main thread while presenting the TCC prompt, which hung
        // the Troubleshooting pane. Permission is requested explicitly from the
        // enable flow / a "Grant" button instead. Opening without the grant
        // succeeds but silently delivers no reports.
        // DEVICE-level input-report callbacks (registered per matched device in
        // the DeviceMatching callback, each with its own buffer). The
        // MANAGER-level report callback traps in IOKit because it has no
        // per-device buffer to hand the device applier. Scheduled on the main
        // run loop so the trivial report decode and the ControllerForwarder
        // reads share one thread.

        // NON-exclusive (kIOHIDOptionsTypeNone): we never seize the pad - the
        // open is shared with gamecontrollerd so GCController keeps everything
        // it already provides (sticks/face/triggers/touchpad/rumble/light), and
        // we read the centre buttons + battery alongside it. A non-exclusive
        // open still permits IOHIDDeviceSetReport(Output) - the adaptive-trigger
        // write path below - for an already-matched device (degrades to a clean
        // no-op if the write is refused; see writeOutputReport).
        let rc = openManager()
        // The manager is reused across streams, and IOKit fires the matching
        // callback only for a pad it hasn't seen: after stop() closed it, a pad
        // that stayed connected never matched again, so every stream after the
        // first one in an app run had no raw HID - no trigger effects, haptics
        // as plain rumble over Bluetooth (measured 2026-11-16). Register what
        // is already there; registerDevice skips a pad it already has.
        if let known = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in known { registerDevice(device) }
        }
        DispatchQueue.main.async { [weak self] in self?.startSelfCheck() }
        // NOTICE (was INFO): the open-rc + Input-Monitoring state is the one fact
        // that tells "are the DualSense centre buttons / battery actually
        // readable" - and it being INFO-only made the broken-quit-chord regression
        // un-diagnosable from shipped logs. Ship it.
        let monitoring = Self.accessGranted ? "granted"
            : (Self.accessDenied ? "DENIED" : "not-yet-determined")
        let usable = (rc == kIOReturnSuccess && Self.accessGranted)
        let buttonsState = usable ? "available"
            : "UNAVAILABLE (reports won't deliver until Input Monitoring is granted)"
        Diag.notice("DualSense HID open rc=0x\(String(rc, radix: 16)) inputMonitoring=\(monitoring) "
            + "- raw-HID centre buttons/battery \(buttonsState)", "Controller")
    }

    // MARK: Self-check (pads that came and went without telling us)

    /// While open, once a second: the DualSenses macOS has against the ones
    /// we hold. A USB pad unplugged and back on Bluetooth produced neither a
    /// removal nor a match callback (MacBook 2026-11-16): the reader kept the
    /// dead USB device, tied the slot to it, and every trigger write was
    /// refused while the Bluetooth pad sat unseen. A mismatch rebuilds.
    private var selfCheckTimer: DispatchSourceTimer?

    private func startSelfCheck() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.selfCheck() }
        timer.resume()
        selfCheckTimer = timer
    }

    /// Registry IDs of the DualSense HID services macOS has now.
    static func liveServiceIDs() -> Set<UInt64> {
        guard let match = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary? else { return [] }
        match[kIOHIDVendorIDKey] = 0x054C
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var ids: Set<UInt64> = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let product = IORegistryEntryCreateCFProperty(service, kIOHIDProductIDKey as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            guard product == 0x0CE6 || product == 0x0DF2 else { continue }
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS { ids.insert(id) }
        }
        return ids
    }

    private static func serviceID(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        guard service != 0, IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { return 0 }
        return id
    }

    private func selfCheck() {
        lock.lock()
        guard running else { lock.unlock(); return }
        let held = Set(writeDevices.values.map { Self.serviceID($0.device) })
        lock.unlock()
        let live = Self.liveServiceIDs()
        guard live != held else { return }
        Diag.notice("DualSense HID: macOS has \(live.count) pad(s), the reader \(held.count) - reconnecting", "Controller")
        rebuild()
    }

    /// Drop every device and the manager, and open a fresh one. Each slot's
    /// last output (`slotOutputs`) stays and goes back to its pad once tied.
    private func rebuild() {
        lock.lock()
        let registered = writeDevices.keys.compactMap { reportBuffers[$0] }
        writeDevices.removeAll()
        padInputs.removeAll()
        slotDevices.removeAll()
        bindVotes.removeAll()
        padOutputs.removeAll()
        padDirtyTriggers.removeAll()
        lock.unlock()
        for (device, buffer) in registered {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, bufLen, nil, nil)
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = Self.makeManager()
        let rc = openManager()
        if let known = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in known { registerDevice(device) }
        }
        Diag.notice("DualSense HID reopened rc=0x\(String(UInt32(bitPattern: rc), radix: 16)), "
            + "\(lock.withLock { writeDevices.count }) pad(s)", "Controller")
        onDevicesChanged?()
    }

    private func stop() {
        selfCheckTimer?.cancel()
        selfCheckTimer = nil
        // Best-effort: park the triggers (and re-emit current light/rumble) so
        // a stream ending mid-effect doesn't strand a stiff trigger on the pad.
        // MUST run BEFORE IOHIDManagerClose - the SetReport needs the manager
        // (and the device's open) still live, and writeDevices still populated.
        cancelHapticsKeepAlive()
        resetTriggersBeforeClose()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        // Clear each pad's report callback (its buffer stays allocated, see
        // reportBuffers), then close.
        lock.lock()
        let registered = writeDevices.keys.compactMap { reportBuffers[$0] }
        lock.unlock()
        for (device, buffer) in registered {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, bufLen, nil, nil)
        }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        lock.lock()
        writeDevices.removeAll()
        padInputs.removeAll()
        slotDevices.removeAll()
        bindVotes.removeAll()
        batteryLocked = nil
        reportCountLocked = 0
        outputState = DualSenseOutputState()
        padOutputs.removeAll()
        padDirtyTriggers.removeAll()
        slotOutputs.removeAll()
        // A request the pad never confirmed would time the next session's
        // first write from this one.
        triggerRequestedAt = 0
        lock.unlock()
        log.info("DualSense HID closed")
    }

    // MARK: Device match / removal

    private static let deviceMatched: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<DualSenseHID>.fromOpaque(context).takeUnretainedValue().registerDevice(device)
    }
    private static let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<DualSenseHID>.fromOpaque(context).takeUnretainedValue().unregisterDevice(device)
    }

    private func registerDevice(_ device: IOHIDDevice) {
        let key = Unmanaged.passUnretained(device).toOpaque()
        // Transport classification for the OUTPUT report (USB 0x02 vs BT 0x31 +
        // CRC). kIOHIDTransportKey is a string like "USB" / "Bluetooth"; treat
        // anything that isn't plain USB as Bluetooth (covers "Bluetooth" and
        // "Bluetooth Low Energy"), the conservative choice since BT needs the
        // CRC the device would otherwise reject.
        let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? ""
        let isBluetooth = !transport.localizedCaseInsensitiveContains("usb")
        lock.lock()
        // Already registered this run (the manager re-reports a pad it knows),
        // or a match that arrived after stop().
        guard running, writeDevices[key] == nil else { lock.unlock(); return }
        let buf: UnsafeMutablePointer<UInt8>
        if let known = reportBuffers[key] {
            buf = known.buffer
        } else {
            buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufLen)
            buf.initialize(repeating: 0, count: bufLen)
            reportBuffers[key] = (device: device, buffer: buf)
        }
        // Stored as a strong Swift reference - ARC retains the bridged CF
        // object for the lifetime of the map entry, so a SetReport can't race
        // device deallocation. (The `key` opaque pointer is only an identity
        // token, NOT the retain; do not switch this value to Unmanaged.)
        writeDevices[key] = (device: device, bluetooth: isBluetooth)
        padOutputs[key] = outputState
        padDirtyTriggers[key] = Self.bothTriggers    // a pad that (re)connects gets the current effects
        lock.unlock()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buf, bufLen, Self.reportCallback, ctx)
        Diag.notice("DualSense HID device matched (\(transport))", "Controller")
    }

    private func unregisterDevice(_ device: IOHIDDevice) {
        let key = Unmanaged.passUnretained(device).toOpaque()
        lock.lock()
        let known = writeDevices.removeValue(forKey: key) != nil ? reportBuffers[key] : nil
        padInputs[key] = nil
        padOutputs[key] = nil
        padDirtyTriggers[key] = nil
        for (slot, device) in slotDevices where device == key { slotDevices[slot] = nil }
        lock.unlock()
        // The buffer stays allocated (see reportBuffers): a report already
        // queued for this device may still be copied into it.
        if let known {
            IOHIDDeviceRegisterInputReportCallback(device, known.buffer, bufLen, nil, nil)
        }
    }

    // MARK: Report decode

    // C-function-pointer-compatible (no captures). `report` is non-optional.
    private static let reportCallback: IOHIDReportCallback = { context, result, sender, _, reportID, report, reportLength in
        guard result == kIOReturnSuccess, let context else { return }
        let me = Unmanaged<DualSenseHID>.fromOpaque(context).takeUnretainedValue()
        // A report queued before stop() can still arrive after it.
        me.lock.lock()
        let live = me.running
        me.lock.unlock()
        guard live else { return }
        // `sender` is the IOHIDDevice, the same pointer registerDevice keys by.
        me.decode(device: sender, reportID: reportID, report: report, length: reportLength)
    }

    /// Per-report entry from the IOKit callback: the pure decode lives in
    /// DualSenseHID+Decode.swift; this half owns the lock, the change edge,
    /// and the main-queue hop to `onChange`.
    private func decode(device: UnsafeMutableRawPointer?, reportID: UInt32,
                        report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        noteTriggerStatus(report: report, length: length)
        guard let decoded = Self.decodeInputReport(
            reportID: reportID, bytes: UnsafeBufferPointer(start: report, count: length)) else { return }

        lock.lock()
        if let nextBattery = decoded.battery { batteryLocked = nextBattery }
        reportCountLocked += 1
        var changed = false
        var axesSlot: UInt8?
        if let device, writeDevices[device] != nil {
            let before = padInputs[device]
            changed = before?.extras != decoded.buttons
            padInputs[device] = (decoded.buttons, decoded.signature, decoded.axes)
            if decoded.axes != nil, before?.axes != decoded.axes {
                axesSlot = slotDevices.first { $0.value == device }?.key
            }
        }
        let notify = onChange
        let notifyAxes = onAxesChange
        lock.unlock()
        if let axesSlot, let notifyAxes {
            DispatchQueue.main.async { MainActor.assumeIsolated { notifyAxes(axesSlot) } }
        }

        if changed, let notify {
            DispatchQueue.main.async { MainActor.assumeIsolated { notify() } }
        }
    }

    // MARK: OUTPUT report (adaptive triggers + lightbar/rumble merge)
    //
    // The DualSense OUTPUT report (0x02 over USB, 0x31 + CRC over Bluetooth)
    // carries rumble, lightbar and BOTH adaptive-trigger blocks, each gated by
    // a valid-flag bit. Every write re-emits the merged `outputState` so a
    // trigger update keeps the host's lightbar and rumble. (Wire facts: SDL SDL_hidapi_ps5.c DS5EffectsState_t,
    // Sunshine adaptive-trigger pass-through, Linux hid-playstation.c CRC seed.)

    /// Apply a host SET_ADAPTIVE_TRIGGERS (0x5503) to the open DualSense. Only
    /// the trigger blocks whose `eventFlags` bit is set are updated (the other
    /// is left at its current state); `typeLeft`/`typeRight` are the
    /// DualSense-native mode bytes and `left`/`right` are the 10 param bytes -
    /// passed straight through (moonlight-qt's shape). A no-op when no device is
    /// open or the write is refused.
    func setAdaptiveTriggers(slot: UInt8?, eventFlags: UInt8, typeLeft: UInt8, typeRight: UInt8,
                             left: [UInt8], right: [UInt8]) {
        // DS_EFFECT_RIGHT_TRIGGER 0x04 / DS_EFFECT_LEFT_TRIGGER 0x08.
        let wantRight = (eventFlags & 0x04) != 0
        let wantLeft = (eventFlags & 0x08) != 0
        guard wantRight || wantLeft else { return }
        let leftBlock = Self.triggerBlock(mode: typeLeft, params: left)
        let rightBlock = Self.triggerBlock(mode: typeRight, params: right)
        lock.lock()
        // Per side and per pad: the console sends both triggers in every
        // message, and asserting an unchanged side restarts its effect (Sony's
        // app flags only the side a request changes).
        if slot == nil {
            if wantLeft { outputState.leftTrigger = leftBlock }
            if wantRight { outputState.rightTrigger = rightBlock }
        }
        for key in slot.map({ [$0] }) ?? Array(slotOutputs.keys) {
            var state = slotOutputs[key] ?? outputState
            if wantLeft { state.leftTrigger = leftBlock }
            if wantRight { state.rightTrigger = rightBlock }
            slotOutputs[key] = state
        }
        var changed = false
        for key in targets(forSlot: slot) {
            var state = padOutputs[key] ?? outputState
            var sides: UInt8 = 0
            if wantLeft, state.leftTrigger != leftBlock { state.leftTrigger = leftBlock; sides |= Self.flagLeftTrigger }
            if wantRight, state.rightTrigger != rightBlock { state.rightTrigger = rightBlock; sides |= Self.flagRightTrigger }
            padOutputs[key] = state
            if sides != 0 { padDirtyTriggers[key, default: 0] |= sides; changed = true }
        }
        triggerUpdates += 1
        if changed {
            triggerChanges += 1
            if triggerRequestedAt == 0 { triggerRequestedAt = DispatchTime.now().uptimeNanoseconds }
        }
        lock.unlock()
        // The PS5 repeats the same effect many times a second. Writing it again
        // restarts the pad's effect (a vibrating trigger stutters) and, over
        // Bluetooth, takes a link slot from the haptics. The pad holds the
        // last effect, so only a change goes out.
        if changed { scheduleWrite() }
    }

    /// The pads a request for `slot` goes to (`lock` held): nil, every pad;
    /// a slot tied to its pad, that pad; a slot not tied yet, every pad no
    /// other slot has claimed (with one pad, that pad).
    func targets(forSlot slot: UInt8?) -> [UnsafeMutableRawPointer] {
        let all = Array(writeDevices.keys)
        guard let slot else { return all }
        if let bound = slotDevices[slot], writeDevices[bound] != nil { return [bound] }
        let claimed = Set(slotDevices.filter { $0.key != slot }.map(\.value))
        return all.filter { !claimed.contains($0) }
    }

    /// Change the OUTPUT state of `slot`'s pad(s) (`lock` held); nil changes
    /// every pad and the state a new pad starts from.
    func mutateOutput(slot: UInt8?, _ body: (inout DualSenseOutputState) -> Void) {
        if let slot {
            var state = slotOutputs[slot] ?? outputState
            body(&state)
            slotOutputs[slot] = state
        } else {
            body(&outputState)
            for key in Array(slotOutputs.keys) { body(&slotOutputs[key]!) }
        }
        for key in targets(forSlot: slot) {
            var state = padOutputs[key] ?? outputState
            body(&state)
            padOutputs[key] = state
        }
    }

    /// Feed the host's latest lightbar color into the merged output state
    /// (called by ControllerHaptics when raw-HID is live). Does NOT itself
    /// write - the lightbar still rides GameController's GCDeviceLight; this
    /// only keeps our merge current so an adaptive-trigger write re-emits the
    /// right color instead of blanking the bar.
    func setLightbarState(slot: UInt8? = nil, red: UInt8, green: UInt8, blue: UInt8) {
        lock.lock()
        mutateOutput(slot: slot) {
            $0.lightR = red; $0.lightG = green; $0.lightB = blue
            $0.lightSet = true
        }
        lock.unlock()
    }

    /// Feed the host's latest rumble pair into the merged output state (8-bit,
    /// already down-scaled from the 16-bit wire by the caller). Merge-only, like
    /// setLightbarState - rumble itself still rides GameController haptics, but
    /// a trigger write has to carry it: a report without the rumble bits drops
    /// the pad out of rumble mode and would silence GameController's motors.
    func setRumbleState(slot: UInt8? = nil, left: UInt8, right: UInt8) {
        lock.lock()
        var stopped = false
        mutateOutput(slot: slot) {
            if ($0.rumbleLeft != 0 || $0.rumbleRight != 0) && left == 0 && right == 0 { stopped = true }
            $0.rumbleLeft = left; $0.rumbleRight = right
        }
        let devices = !writeDevices.isEmpty
        lock.unlock()
        // A trigger write taken just before the stop may still carry the old
        // motor values; land a report after it so the motors don't stay on.
        if stopped, devices { scheduleWrite() }
    }

    /// Park the triggers to neutral and re-emit, called from stop() while the
    /// device is still open. Best-effort - a refused write is fine, the pad
    /// loses power on disconnect anyway.
    private func resetTriggersBeforeClose() {
        lock.lock()
        let hadDevice = !writeDevices.isEmpty
        mutateOutput(slot: nil) {
            $0.leftTrigger = [UInt8](repeating: 0, count: 11)
            $0.rightTrigger = [UInt8](repeating: 0, count: 11)
        }
        for key in writeDevices.keys { padDirtyTriggers[key] = Self.bothTriggers }
        lock.unlock()
        guard hadDevice else { return }
        // Synchronous on the write queue so it completes before the manager
        // closes underneath us (stop() clears writeDevices right after).
        writeQueue.sync { self.writeCurrentOutput() }
    }

    /// One trigger block = [mode][10 params], clamped to 11 bytes. Rejects the
    /// 0xFC-0xFE debug/calibration modes (they can corrupt trigger state) by
    /// neutralizing to "off" - defensive against a malformed host value.
    private static func triggerBlock(mode: UInt8, params: [UInt8]) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 11)
        guard mode < 0xFC else { return block } // 0x00 = off
        block[0] = mode
        for i in 0..<min(params.count, 10) { block[i + 1] = params[i] }
        return block
    }

    /// The first open DualSense connected over Bluetooth, if any.
    func bluetoothPad() -> IOHIDDevice? {
        lock.lock(); defer { lock.unlock() }
        return writeDevices.values.first { $0.bluetooth }?.device
    }

    /// Write the merged state soon. Requests coalesce: a write reads the
    /// newest state when it runs, so while one is waiting, more requests add
    /// nothing. That matters over Bluetooth, where a write takes 30 ms or
    /// more and the console sends trigger changes in bursts - one write per
    /// change queued them up into a felt delay.
    /// Trigger effects the host sent, and how many of them changed anything
    /// (session breadcrumbs; `lock`).
    var triggerUpdates = 0
    var triggerChanges = 0
    static let bothTriggers: UInt8 = flagRightTrigger | flagLeftTrigger
    /// Trigger latency breadcrumbs (`lock`): when the oldest unapplied change
    /// arrived, when its write finished, and the pad's own trigger-status
    /// bytes (USB input report 0x01, bytes 42/43/48: the effect it is running).
    var triggerRequestedAt: UInt64 = 0
    var triggerStatus: UInt32 = 0
    var triggerWriteMs: [Double] = []
    var triggerApplyMs: [Double] = []

    /// "<updates> trigger effects (<changes> changes), written in .., applied in ..", then reset.
    func takeTriggerStats() -> String {
        lock.lock(); defer { lock.unlock() }
        defer {
            triggerUpdates = 0; triggerChanges = 0
            triggerWriteMs.removeAll(); triggerApplyMs.removeAll()
        }
        func q(_ v: [Double]) -> String {
            guard !v.isEmpty else { return "-" }
            let s = v.sorted()
            return String(format: "p50 %.1f p99 %.1f ms (%d)", s[s.count / 2], s[min(s.count - 1, s.count * 99 / 100)], s.count)
        }
        return "\(triggerUpdates) trigger effects (\(triggerChanges) changes), written \(q(triggerWriteMs)), "
            + "applied on the pad \(q(triggerApplyMs))"
    }

    /// The pad's trigger-status bytes changed: close out the pending change's
    /// apply latency (USB report 0x01; a change older than 250 ms is assumed
    /// to have produced no status change and is dropped).
    func noteTriggerStatus(report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length > 48, report[0] == 0x01 else { return }
        let status = UInt32(report[42]) | UInt32(report[43]) << 8 | UInt32(report[48]) << 16
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock(); defer { lock.unlock() }
        if triggerRequestedAt != 0, now &- triggerRequestedAt > 250_000_000 { triggerRequestedAt = 0 }
        guard status != triggerStatus else { return }
        triggerStatus = status
        if triggerRequestedAt != 0, triggerApplyMs.count < 10_000 {
            triggerApplyMs.append(Double(now &- triggerRequestedAt) / 1e6)
            triggerRequestedAt = 0
        }
    }

    func scheduleWrite() {
        lock.lock()
        let alreadyPending = writePending
        writePending = true
        writeRequestedAt = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        guard !alreadyPending else { return }
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.writePending = false; self.lock.unlock()
            self.writeCurrentOutput()
            self.lock.lock(); self.controlWriteDone = DispatchTime.now().uptimeNanoseconds; self.lock.unlock()
        }
    }

    /// True from a write request until its report is out: the Bluetooth
    /// haptics sender holds its next report so the trigger change goes first.
    var controlWriteWaiting: Bool {
        lock.lock(); defer { lock.unlock() }
        return writePending || writeRequestedAt > controlWriteDone
    }

    /// Build the merged OUTPUT report from the current state and write it to
    /// every open device. Runs on `writeQueue`.
    /// The trigger blocks go out only when they changed (or a write of them
    /// failed): asserting them again restarts the pad's effect, so a rumble,
    /// light-bar or mute-light write must not carry them.
    func writeCurrentOutput() {
        lock.lock()
        var jobs: [(key: UnsafeMutableRawPointer, device: IOHIDDevice, bluetooth: Bool,
                    state: DualSenseOutputState, triggers: UInt8)] = []
        for (key, entry) in writeDevices {
            jobs.append((key, entry.device, entry.bluetooth, padOutputs[key] ?? outputState, padDirtyTriggers[key] ?? 0))
            padDirtyTriggers[key] = 0
        }
        lock.unlock()
        var wroteTriggers = false
        var allOK = true
        for job in jobs {
            let ok = writeOutputReport(to: job.device, bluetooth: job.bluetooth,
                                       effects: Self.effectsState(job.state, triggerFlags: job.triggers))
            allOK = allOK && ok
            guard job.triggers != 0 else { continue }
            wroteTriggers = true
            if !ok { lock.withLock { padDirtyTriggers[job.key, default: 0] |= job.triggers } }
        }
        if wroteTriggers, allOK {
            lock.lock()
            if triggerRequestedAt != 0, triggerWriteMs.count < 10_000 {
                triggerWriteMs.append(Double(DispatchTime.now().uptimeNanoseconds &- triggerRequestedAt) / 1e6)
            }
            lock.unlock()
        }
    }

    /// First-success latch (lock-guarded). Returns the PRIOR value so the caller
    /// logs only on the first success.
    func loggedWriteWasSuccessful() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let was = loggedWriteSuccess
        loggedWriteSuccess = true
        return was
    }
    /// First-failure latch (lock-guarded), same shape.
    func loggedWriteWasRefused() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let was = loggedWriteFailure
        loggedWriteFailure = true
        return was
    }
}
