//
//  AWDLGuard.swift
//
//  "Reduce lag spikes on Wi-Fi": while a stream runs over Wi-Fi, keep awdl0
//  (the Apple Wireless Direct Link behind AirDrop, AirPlay, Sidecar and
//  Continuity) down, because it makes the Wi-Fi radio hop channels and stalls
//  the stream for tens to hundreds of milliseconds.
//
//  The earlier version was a root LaunchDaemon (removed 2026-11-09): it needed a
//  Login Items approval and then failed macOS 27.2's launch constraints. This
//  one has no daemon. A one-time admin prompt installs a sudoers rule that lets
//  this user run exactly `/sbin/ifconfig awdl0 down` and `/sbin/ifconfig awdl0
//  up` without a password; Shimmer itself watches the interface during a
//  stream (routing socket + 1 s poll) and lowers it again whenever macOS
//  raises it. awdl0 comes back up when the stream ends, when the app quits,
//  and - if Shimmer died mid-stream - at the next launch (a marker file).
//

import AppKit
import CoreWLAN
import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class AWDLGuard {
    static let shared = AWDLGuard()

    static let sudoersPath = "/etc/sudoers.d/shimmer-awdl"
    static let enabledKey = "reduceWiFiLagSpikes"

    /// The user's setting.
    var enabled: Bool = UserDefaults.standard.bool(forKey: AWDLGuard.enabledKey) {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    /// The sudoers rule is in place (checked without prompting).
    private(set) var permissionInstalled = false
    private(set) var installing = false
    private(set) var lastError: String?

    private let parker = AWDLParker()

    private init() {
        // No subprocess here: `sudo -n -l` blocked in waitUntilExit(), which
        // spins the main run loop - inside the dispatch_once that builds
        // `shared`, so any queued main-thread work touching AWDLGuard.shared
        // trapped ("BUG IN CLIENT OF LIBDISPATCH: trying to lock recursively"),
        // and the first stream start stalled the UI on sudo. The rule file's
        // presence is the instant answer; sudo confirms it off the main thread.
        permissionInstalled = FileManager.default.fileExists(atPath: Self.sudoersPath)
        Task { await refreshPermission() }
    }

    /// Ask sudo (off the main thread) whether the rule works without a password.
    func refreshPermission() async {
        let ok = await Task.detached(priority: .utility) { AWDLParker.canToggleWithoutPassword() }.value
        permissionInstalled = ok
    }

    /// The Settings toggle. Turning it on the first time installs the rule
    /// (one macOS admin prompt); declining the prompt leaves it off.
    func setEnabled(_ on: Bool) {
        guard on else { enabled = false; return }
        installing = true
        lastError = nil
        Task {
            await refreshPermission()
            if permissionInstalled { installing = false; enabled = true; return }
            let result = await Self.installPermission()
            installing = false
            await refreshPermission()
            if permissionInstalled {
                enabled = true
                Diag.notice("Wi-Fi lag-spike reduction set up", "AWDL")
            } else {
                lastError = result
            }
        }
    }

    // MARK: Stream edges

    /// A stream went live. Parks awdl0 when the setting is on, the permission
    /// is in place, and the route to the host leaves over Wi-Fi.
    func streamStarted(hostAddress: String) {
        guard enabled, permissionInstalled else { return }
        let parker = self.parker
        Task.detached(priority: .userInitiated) {
            guard let interface = AWDLParker.routeInterface(to: hostAddress) else { return }
            guard AWDLParker.isWiFi(interface) else {
                Diag.info("Stream route is \(interface), not Wi-Fi - leaving AWDL alone", "AWDL")
                return
            }
            parker.engage()
        }
    }

    func streamEnded() {
        parker.disengage(reason: "stream ended")
    }

    /// App quit: restore synchronously.
    func appWillTerminate() {
        parker.disengage(reason: "app quit", synchronous: true)
    }

    /// Launch: a marker means the last run parked awdl0 and never restored it.
    func recoverAtLaunch() {
        parker.recoverIfMarked()
    }

    // MARK: Permission install

    /// Install the sudoers rule through the standard admin prompt. Returns an
    /// error message, or nil on success.
    private static func installPermission() async -> String? {
        let user = NSUserName()
        guard user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            return "Your account name can't be used in a sudo rule."
        }
        // Validated with visudo before install; sudo ignores sudoers.d files whose
        // names contain a dot, so the name has none.
        let script = """
        set -e
        grep -Eq '^[#@]includedir[[:space:]]+/(private/)?etc/sudoers\\.d' /etc/sudoers
        f=$(/usr/bin/mktemp /tmp/shimmer-awdl.XXXXXX)
        printf '%s ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 down, /sbin/ifconfig awdl0 up\\n' '\(user)' > "$f"
        /usr/sbin/visudo -cf "$f" >/dev/null
        /usr/bin/install -m 0440 -o root -g wheel "$f" \(sudoersPath)
        rm -f "$f"
        """
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges "
            + "with prompt \"Shimmer wants to pause AirDrop's Wi-Fi link while you stream.\""
        return await MainActor.run {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else { return nil }
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "Cancelled." }
            return (error[NSAppleScript.errorMessage] as? String) ?? "The permission couldn't be installed."
        }
    }
}

/// The interface work, off the main actor. One serial queue owns all state.
final class AWDLParker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Shimmer.AWDL", qos: .userInitiated)
    private var engaged = false
    private var routeSource: DispatchSourceRead?
    private var routeFD: Int32 = -1
    private var pollTimer: DispatchSourceTimer?
    private var reRaises = 0

    static let interface = "awdl0"

    private static var markerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shimmer", isDirectory: true)
            .appendingPathComponent("awdl-parked")
    }

    // MARK: Engage / disengage

    func engage() {
        queue.async { [self] in
            guard !engaged else { return }
            engaged = true
            reRaises = 0
            try? FileManager.default.createDirectory(at: Self.markerURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: Self.markerURL.path, contents: Data())
            lowerIfUp()
            startWatching()
            Diag.notice("AWDL parked for the stream (Wi-Fi route)", "AWDL")
        }
    }

    func disengage(reason: String, synchronous: Bool = false) {
        let work = { [self] in
            guard engaged else { return }
            engaged = false
            stopWatching()
            Self.runIfconfig("up")
            try? FileManager.default.removeItem(at: Self.markerURL)
            Diag.notice("AWDL restored (\(reason); macOS raised it \(reRaises)x during the stream)", "AWDL")
        }
        if synchronous { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    func recoverIfMarked() {
        queue.async { [self] in
            // A park already started in this run owns the marker.
            guard !engaged, FileManager.default.fileExists(atPath: Self.markerURL.path) else { return }
            Self.runIfconfig("up")
            try? FileManager.default.removeItem(at: Self.markerURL)
            Diag.notice("AWDL restored at launch (the last session ended without restoring it)", "AWDL")
        }
    }

    // MARK: Watching (queue only)

    private func startWatching() {
        // Routing socket: the kernel announces every interface flag change.
        let fd = socket(PF_ROUTE, SOCK_RAW, 0)
        if fd >= 0 {
            routeFD = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.drainRouteSocket() }
            source.setCancelHandler { close(fd) }
            source.resume()
            routeSource = source
        }
        // Fallback poll.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.lowerIfUp(reRaise: true) }
        timer.resume()
        pollTimer = timer
    }

    private func stopWatching() {
        routeSource?.cancel()
        routeSource = nil
        routeFD = -1
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func drainRouteSocket() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        let n = read(routeFD, &buffer, buffer.count)
        guard n >= MemoryLayout<if_msghdr>.size else { return }
        let index = if_nametoindex(Self.interface)
        buffer.withUnsafeBytes { raw in
            let msg = raw.load(as: if_msghdr.self)
            if Int32(msg.ifm_type) == RTM_IFINFO, UInt32(msg.ifm_index) == index,
               msg.ifm_flags & IFF_UP != 0 {
                lowerIfUp(reRaise: true)
            }
        }
    }

    private func lowerIfUp(reRaise: Bool = false) {
        guard engaged, Self.isUp() else { return }
        if reRaise { reRaises += 1 }
        Self.runIfconfig("down")
    }

    // MARK: Helpers

    static func isUp() -> Bool {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return false }
        defer { freeifaddrs(addrs) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            if String(cString: cur.pointee.ifa_name) == interface {
                return cur.pointee.ifa_flags & UInt32(IFF_UP) != 0
            }
            p = cur.pointee.ifa_next
        }
        return false
    }

    @discardableResult
    static func runIfconfig(_ action: String) -> Bool {
        run("/usr/bin/sudo", ["-n", "/sbin/ifconfig", interface, action]) == 0
    }

    /// The rule is installed and needs no password (never prompts).
    static func canToggleWithoutPassword() -> Bool {
        run("/usr/bin/sudo", ["-n", "-l", "/sbin/ifconfig", interface, "down"]) == 0
    }

    /// The interface the route to `address` leaves on (e.g. "en0").
    static func routeInterface(to address: String) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", address]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Read to EOF first (a full pipe would block the child), then reap.
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text.split(separator: "\n")
            .first { $0.contains("interface:") }?
            .split(separator: ":").last?
            .trimmingCharacters(in: .whitespaces)
    }

    static func isWiFi(_ interface: String) -> Bool {
        CWWiFiClient.shared().interfaceNames()?.contains(interface) ?? false
    }

    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // terminationHandler + semaphore rather than waitUntilExit(), which
        // spins the calling thread's run loop and runs whatever else is queued
        // there in the middle of this call.
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return -1 }
        done.wait()
        return process.terminationStatus
    }
}
