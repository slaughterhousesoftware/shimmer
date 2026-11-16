// btrate: how many silent 0x32 reports/s the BT link completes with N in flight.
// args: inflight seconds
import Foundation
import IOKit.hid
setvbuf(stdout, nil, _IONBF, 0)
let inflight = Int(CommandLine.arguments[1])!
let seconds = Double(CommandLine.arguments[2])!
func crc(_ b: UnsafeMutablePointer<UInt8>, _ n: Int) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    func feed(_ byte: UInt8) { c ^= UInt32(byte); for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 } }
    feed(0xA2); for i in 0..<n { feed(b[i]) }
    return c ^ 0xFFFF_FFFF
}
let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x054C, kIOHIDTransportKey: "Bluetooth"] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(m, 0)
guard let pad = ((IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? []).first else { print("no BT pad"); exit(1) }
var seq: UInt8 = 0, counter: UInt8 = 0
let slots = (0..<inflight).map { _ in UnsafeMutablePointer<UInt8>.allocate(capacity: 142) }
var busy = [Bool](repeating: false, count: inflight)
var sentAt = [UInt64](repeating: 0, count: inflight)
var done = 0, failed = 0, lat: [Double] = []
let cb: IOHIDReportCallback = { _, result, _, _, _, report, _ in
    if let i = slots.firstIndex(where: { $0 == report }) {
        busy[i] = false
        lat.append(Double(DispatchTime.now().uptimeNanoseconds - sentAt[i]) / 1e6)
    }
    if result == kIOReturnSuccess { done += 1 } else { failed += 1 }
}
func build(_ r: UnsafeMutablePointer<UInt8>) {
    r.update(repeating: 0, count: 142)
    r[0] = 0x32; r[1] = seq << 4; seq = (seq + 1) & 0x0F
    r[2] = 0x91; r[3] = 4; r[4] = 0x66; r[5] = 48; r[6] = 48; r[7] = counter; counter &+= 2
    r[8] = 0xD2; r[9] = 64
    let c = crc(r, 138); for i in 0..<4 { r[138 + i] = UInt8((c >> (8 * UInt32(i))) & 0xFF) }
}
let start = Date()
while Date().timeIntervalSince(start) < seconds {
    if let i = busy.firstIndex(of: false) {
        busy[i] = true; build(slots[i]); sentAt[i] = DispatchTime.now().uptimeNanoseconds
        let rc = IOHIDDeviceSetReportWithCallback(pad, kIOHIDReportTypeOutput, 0x32, slots[i], 142, 1.0, cb, nil)
        if rc != kIOReturnSuccess { busy[i] = false; failed += 1 }
    }
    CFRunLoopRunInMode(.defaultMode, 0.001, true)
}
CFRunLoopRunInMode(.defaultMode, 0.3, false)
lat.sort()
let p = { (q: Double) -> String in lat.isEmpty ? "-" : String(format: "%.1f", lat[min(lat.count - 1, Int(Double(lat.count) * q))]) }
print("inflight \(inflight): \(String(format: "%.1f", Double(done) / seconds)) reports/s, latency p50 \(p(0.5)) p95 \(p(0.95)) ms, failed \(failed)")
