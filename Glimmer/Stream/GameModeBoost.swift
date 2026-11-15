//
//  GameModeBoost.swift
//
//  macOS Game Mode while a stream drives a Bluetooth controller, in any
//  window mode (picture in picture included).
//
//  Game Mode halves a Bluetooth game controller's sniff interval: bluetoothd
//  logs "applyHIDSniffIntervalGameControllers: ... shifting to 7.50 ms" the
//  moment it turns on, and back to 15 ms when it ends. Every DualSense output
//  report (haptics, triggers) waits for those slots, so it roughly doubles
//  what the link carries and halves trigger latency (measured on Kevin's
//  MacBook, 2026-11-15).
//
//  On its own, macOS turns Game Mode on only for an app in the games category
//  that is frontmost in native (Space) full screen. Shimmer's full screen is a
//  borderless window and PiP is neither, so it never triggers. Apple's
//  `gamepolicyctl` (Xcode's developer tools) can force the policy on; the
//  daemon's tool interface needs Apple's private entitlement, so we run that
//  tool rather than call it ourselves. No Xcode, no boost - nothing breaks.
//
//  Only a policy we found on "automatic" is touched, and it goes back to
//  automatic when the last stream lets go (or at the next launch, after a
//  crash).
//

import Foundation

final class GameModeBoost: @unchecked Sendable {

    static let shared = GameModeBoost()

    private let queue = DispatchQueue(label: "Shimmer.GameModeBoost")
    private var holders = 0             // `queue`
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

    /// A stream wants Game Mode (a Bluetooth controller is feeding it).
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
