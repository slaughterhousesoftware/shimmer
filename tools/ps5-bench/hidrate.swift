import Foundation
import IOKit.hid
let secs = Double(CommandLine.arguments[1])!
let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x054C, kIOHIDTransportKey: "Bluetooth"] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(m, 0)
guard let dev = ((IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? []).first else { print("no BT pad"); exit(1) }
var times: [UInt64] = []
let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
IOHIDDeviceRegisterInputReportCallback(dev, buf, 128, { _, _, _, _, _, _, _ in times.append(DispatchTime.now().uptimeNanoseconds) }, nil)
CFRunLoopRunInMode(.defaultMode, secs, false)
let iv = zip(times, times.dropFirst()).map { Double($1 - $0) / 1e6 }.sorted()
func q(_ p: Double) -> String { iv.isEmpty ? "-" : String(format: "%.1f", iv[min(iv.count - 1, Int(Double(iv.count) * p))]) }
print("input reports/s \(Int(Double(times.count) / secs)), interval p50 \(q(0.5)) p99 \(q(0.99)) max \(q(1)) ms")
