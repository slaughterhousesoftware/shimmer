//
//  GameModeBoost.swift
//
//  macOS Game Mode while any stream (Sunshine or PS5) is live with a Bluetooth
//  controller connected, in any window mode (picture in picture included).
//
//  Game Mode halves a Bluetooth game controller's sniff interval: bluetoothd
//  logs "applyHIDSniffIntervalGameControllers: ... shifting to 7.50 ms" the
//  moment it turns on, and back to 15 ms when it ends. Measured on Kevin's
//  M5 MacBook with a Bluetooth DualSense (2026-11-15):
//                         Game Mode off     on
//    input reports        64/s (15 ms)      132/s (7.6 ms)
//    output reports       34/s, 33 ms each  66/s, 18 ms each
//  so it halves input latency over Bluetooth, and DualSense haptics (47
//  reports/s) only fit on the link with it on.
//
//  On its own, macOS turns Game Mode on only for an app in the games category
//  that is frontmost in native (Space) full screen - Shimmer's full screen,
//  but not a window or PiP. Apple's
//  `gamepolicyctl` (Xcode's developer tools) can force the policy on; the
//  daemon's tool interface needs Apple's private entitlement, so we run that
//  tool rather than call it ourselves. No Xcode, no boost - nothing breaks.
//
//  Only a policy we found on "automatic" is touched, and it goes back to
//  automatic when the last stream lets go (or at the next launch, after a
//  crash).
//

import Foundation
import GameController
import IOKit.hid

final class GameModeBoost: @unchecked Sendable {

    static let shared = GameModeBoost()

    private init() { observeControllers() }

    private let queue = DispatchQueue(label: "Shimmer.GameModeBoost")
    private var holders = 0             // `queue`
    private var streamHeld = false      // `queue`
    private var forcedByUs = false      // `queue`
    private static let forcedKey = "GameModeForcedByShimmer"
    private static let logCategory = "GameMode"

    /// Xcode's gamepolicyctl, if this Mac has it. Looked up by path only: a
    /// bare `xcrun` would offer to install the developer tools.
    static func tool() -> String? {
        var dirs: [String] = []
        if let selected = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            dirs.append(selected)
        }
        dirs += ["/Applications/Xcode.app/Contents/Developer", "/Applications/Xcode-beta.app/Contents/Developer"]
        return dirs.map { $0 + "/usr/bin/gamepolicyctl" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The policy, as gamepolicyctl prints it.
    enum Policy: Equatable { case automatic, forcedOn, forcedOff, unknown }

    static func parsePolicy(_ status: String) -> Policy {
        let s = status.lowercased()
        if s.contains("currently automatic") { return .automatic }
        if s.contains("forced always on") { return .forcedOn }
        if s.contains("forced always off") || s.contains("forced off") { return .forcedOff }
        return .unknown
    }

    /// A stream went live (`true`) or ended. Idempotent: both live edges may
    /// call it. Game Mode is held while a stream is live, the setting is on
    /// and a Bluetooth game controller is connected - re-evaluated whenever a
    /// controller connects or disconnects (a DualSense that wakes after the
    /// stream started gets it too; one that leaves gives it back).
    func streamLive(_ live: Bool, enabled: Bool) {
        queue.async { [self] in
            streamIsLive = live
            boostEnabled = enabled
            reevaluate()
        }
    }

    /// The setting changed: applies at once to a stream already live.
    func setEnabled(_ enabled: Bool) {
        queue.async { [self] in
            boostEnabled = enabled
            reevaluate()
        }
    }

    private var streamIsLive = false     // `queue`
    private var boostEnabled = false     // `queue`
    private var controllerObservers: [NSObjectProtocol] = []

    /// GameController's own connect / disconnect notifications. The HID
    /// device's transport can trail the notification a moment, so look again
    /// shortly after as well.
    private func observeControllers() {
        let nc = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            controllerObservers.append(nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.reevaluate() }
                self.queue.asyncAfter(deadline: .now() + 1) { self.reevaluate() }
            })
        }
    }

    /// `queue` only.
    private func reevaluate() {
        let want = streamIsLive && boostEnabled && Self.bluetoothControllerConnected()
        if want, !streamHeld {
            streamHeld = true
            queue.async { self.acquire(reason: "the stream (Bluetooth controller)") }
        } else if !want, streamHeld {
            streamHeld = false
            queue.async { self.release() }
        }
    }

    /// A gamepad or joystick on Bluetooth (any make).
    static func bluetoothControllerConnected() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
        ] as CFArray)
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        return devices.contains {
            ((IOHIDDeviceGetProperty($0, kIOHIDTransportKey as CFString) as? String) ?? "")
                .localizedCaseInsensitiveContains("bluetooth")
        }
    }

    /// Take a hold on Game Mode.
    func acquire(reason: String) {
        queue.async { [self] in
            holders += 1
            guard holders == 1, !forcedByUs, let tool = Self.tool() else {
                if Self.tool() == nil, holders == 1 {
                    Diag.info("Game Mode: no gamepolicyctl (Xcode) on this Mac - Bluetooth stays at 15 ms",
                              Self.logCategory)
                }
                return
            }
            let policy = Self.parsePolicy(Self.run(tool, ["game-mode", "status"]).output)
            guard policy == .automatic else {
                Diag.info("Game Mode policy is \(policy) - left alone", Self.logCategory)
                return
            }
            guard Self.run(tool, ["game-mode", "set", "on"]).status == 0 else {
                Diag.error("Game Mode: gamepolicyctl set on failed", Self.logCategory)
                return
            }
            forcedByUs = true
            UserDefaults.standard.set(true, forKey: Self.forcedKey)
            Diag.notice("Game Mode on for \(reason) (Bluetooth controller at 7.5 ms)", Self.logCategory)
        }
    }

    func release() {
        queue.async { [self] in
            holders = max(0, holders - 1)
            guard holders == 0, forcedByUs else { return }
            restoreAutomatic()
        }
    }

    /// The app is quitting: put the policy back now.
    func releaseAllNow() {
        queue.sync {
            holders = 0
            if forcedByUs { restoreAutomatic() }
        }
    }

    /// A previous run forced it on and didn't get to undo it (crash, kill).
    func recoverAtLaunch() {
        guard UserDefaults.standard.bool(forKey: Self.forcedKey) else { return }
        queue.async { [self] in
            guard holders == 0 else { return }
            restoreAutomatic()
        }
    }

    private func restoreAutomatic() {
        forcedByUs = false
        UserDefaults.standard.removeObject(forKey: Self.forcedKey)
        guard let tool = Self.tool() else { return }
        let ok = Self.run(tool, ["game-mode", "set", "auto"]).status == 0
        Diag.info("Game Mode back to automatic\(ok ? "" : " - failed")", Self.logCategory)
    }

    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
