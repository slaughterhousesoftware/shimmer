//
//  DebugAutomation.swift
//
//  Env-var-gated automation for headless iteration during development. INERT
//  unless the GLIMMER_DEBUG_* variables are set, so it never affects a normal
//  launch. Lets a script drive: pick a host, start a stream, enter Picture in
//  Picture after N seconds, and quit after M seconds - so a capture/inspect/fix
//  loop needs no GUI clicking.
//
//    GLIMMER_DEBUG_STREAM=<substr>   select the first host whose name/address
//                                    contains <substr> (case-insensitive) and
//                                    stream its default app.
//    GLIMMER_DEBUG_PIP_AFTER=<sec>   once streaming, wait <sec> then ⌃⌥P.
//    GLIMMER_DEBUG_QUIT_AFTER=<sec>  quit the app <sec> after streaming starts.
//    GLIMMER_DEBUG_RETURN_AFTER=<sec> <sec> after the PiP entry, resume the
//                                    window (the Dock / menu-bar path).
//    GLIMMER_DEBUG_PIP_PROBE=1       log the whole PiP state machine once a
//                                    second (`PIPPROBE` lines).
//    GLIMMER_DEBUG_PIP_CLOSE_AFTER=<sec>  <sec> after the PiP entry, stop PiP
//                                    with the window left hidden (the × path).
//    GLIMMER_DEBUG_PIP_AGAIN_AFTER=<sec>  <sec> after the PiP entry, enter PiP
//                                    again (the menu-bar path from hidden).
//
//  The same knobs are accepted as command-line arguments
//  (`--debug-stream=<substr> --debug-pip-after=<sec> ...`) because a GUI app
//  launched through LaunchServices (`open -n App.app --args ...`) lives in the
//  gui/<uid> launchd domain and never sees a shell's environment - not even
//  one exported with `launchctl setenv`, which lands in user/<uid> when the
//  shell is an SSH session. Launching via `open` matters: it's what gets the
//  Local Network privacy grant attributed to the app rather than sshd.
//

import AppKit
import Foundation

extension AppModel {

    /// `GLIMMER_DEBUG_<NAME>` from the environment, else `--debug-<name>=value`
    /// from the command line. Only used to decide whether automation is armed;
    /// nothing here runs on a normal launch.
    static func debugKnob(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        if let v = env["GLIMMER_DEBUG_\(name.uppercased().replacingOccurrences(of: "-", with: "_"))"],
           !v.isEmpty { return v }
        let prefix = "--debug-\(name)="
        return ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Render the main window's frame view (title bar included) at 2x.
    private static func snapshotMainWindow(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.level == .normal }),
              let view = window.contentView?.superview ?? window.contentView else { return }
        window.makeKeyAndOrderFront(nil)
        // A sheet is its own window; capture it (as <name>-sheet.png) too.
        if let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview ?? sheet.contentView {
            let sheetURL = url.deletingPathExtension().appendingPathExtension("sheet.png")
            snapshot(sheetView, to: sheetURL)
        }
        snapshot(view, to: url)
    }

    private static func snapshot(_ view: NSView, to url: URL) {
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// `NSApp.terminate` from the RUN LOOP, never from inside a GCD main-queue
    /// block. With a live session, applicationShouldTerminate answers
    /// `.terminateLater` and stops the session in a `@MainActor` task; AppKit
    /// then spins a nested event loop waiting for the reply. Inside a
    /// main-queue callout that task can never run (the queue is serial and we
    /// are still in it), so the app sits in `-[NSApplication terminate:]`
    /// forever with the stream still up. A run-loop-invoked terminate spins a
    /// loop that drains the main queue normally - the Cmd-Q path.
    static func terminateFromRunLoop() {
        RunLoop.main.perform { NSApp.terminate(nil) }
    }

    /// First loaded host whose name or address contains `match`.
    func debugHost(matching match: String) -> Host? {
        let host = hosts.first {
            $0.name.localizedCaseInsensitiveContains(match)
                || ($0.customName?.localizedCaseInsensitiveContains(match) ?? false)
                || ($0.localAddress?.localizedCaseInsensitiveContains(match) ?? false)
                || ($0.manualAddress?.localizedCaseInsensitiveContains(match) ?? false)
        }
        if host == nil {
            log.error("DEBUG automation: no host matching '\(match, privacy: .private)' among \(self.hosts.map(\.name), privacy: .private)")
        }
        return host
    }

    func runDebugAutomationIfRequested() {
        // `--debug-render-avatars=<file.png>`: every host avatar drawn at 4x
        // (no screen, no screenshot), to judge the marks' size and centring.
        if let path = Self.debugKnob("render-avatars") {
            HostAvatar.renderGallery(to: URL(fileURLWithPath: path))
        }
        // `--debug-cycle=<host>:<sec>[,<host>:<sec>...]`: a stress loop for
        // stream start/stop - stream each host for up to <sec> (randomised
        // down to half), end it, wait a random 0.3-4 s, go on to the next,
        // `--debug-cycle-count` rounds (default 50). `--debug-cycle-hide=1`
        // also hides the app for 3 s mid-stream on half the streams. Every
        // step logs a `CYCLE` line, so a crash report lines up with the step.
        if let spec = Self.debugKnob("cycle") {
            runDebugCycle(spec: spec,
                          rounds: Self.debugKnob("cycle-count").flatMap(Int.init) ?? 50,
                          hide: Self.debugKnob("cycle-hide") != nil)
            return
        }
        // `--debug-awdl-park=<seconds>@<host address>`: run the Wi-Fi lag-spike
        // parker exactly as a stream would (route check, park, watch), then
        // restore - for testing it without a live session.
        if let spec = Self.debugKnob("awdl-park") {
            let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
            let seconds = Double(parts.first ?? "") ?? 10
            let address = parts.count > 1 ? parts[1] : "192.168.1.1"
            log.notice("DEBUG automation: parking AWDL for \(seconds)s (route to \(address, privacy: .private))")
            AWDLGuard.shared.streamStarted(hostAddress: address)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                AWDLGuard.shared.streamEnded()
            }
        }
        // `--debug-open-settings=<pane>[,<pane>...]`: open the Settings window
        // on each pane in turn, 3s apart (a screenshot loop for UI work), then
        // quit after --debug-quit-after seconds if given.
        if let panes = Self.debugKnob("open-settings") {
            // Per-process appearance for live window screenshots; never changes
            // the user's system appearance or persists a preference.
            if let appearance = Self.debugKnob("appearance") {
                if appearance == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
                if appearance == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
            }
            let list = panes.split(separator: ",").compactMap { SettingsTab(persisted: String($0)) }
            log.notice("DEBUG automation: opening Settings on \(list.map(\.rawValue), privacy: .public)")
            for (i, pane) in list.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(i) * 3.0) { [weak self] in
                    // The app starts in the menu bar, so the window has to be asked for.
                    AppDelegate.openMainWindow?()
                    NSApp.activate()
                    self?.settingsTab = pane
                }
            }
            // `--debug-snapshot=<dir>`: after each pane opens, save the window
            // at 2x as <dir>/<pane>.png. The dev Mac's 1x display made screen
            // captures look far softer than the Retina laptop the app runs on.
            if let dir = Self.debugKnob("snapshot") {
                for (i, pane) in list.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0 + Double(i) * 3.0) {
                        Self.snapshotMainWindow(to: URL(fileURLWithPath: dir)
                            .appendingPathComponent("\(pane.rawValue).png"))
                    }
                }
            }
            if let quitAfter = Self.debugKnob("quit-after").flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) { Self.terminateFromRunLoop() }
            }
            return
        }
        // `--debug-fetch-artwork=<host substr>`: pull every app's box art from
        // that host and drop it in /tmp, logging sizes. Proves the /appasset
        // endpoint against a real Sunshine before any UI is built on it.
        if let hostMatch = Self.debugKnob("fetch-artwork") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, let host = self.debugHost(matching: hostMatch) else { return }
                Task { @MainActor in
                    let info = self.nativeServerInfo(for: host)
                    let client = NetworkClient(server: info)
                    for app in host.apps {
                        do {
                            let data = try await client.appAsset(appID: app.id)
                            let path = "/tmp/shimmer-art-\(app.id).png"
                            try? data.write(to: URL(fileURLWithPath: path))
                            let magic = data.prefix(4).map { String(format: "%02x", $0) }.joined()
                            self.log.notice("ARTWORK \(app.name, privacy: .public): \(data.count) bytes magic=\(magic, privacy: .public) -> \(path, privacy: .public)")
                        } catch {
                            self.log.error("ARTWORK \(app.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    await client.shutdown()
                    Self.terminateFromRunLoop()
                }
            }
            return
        }
        guard let hostMatch = Self.debugKnob("stream") else { return }
        armLatencyProbeIfRequested()
        // `--debug-pip-probe=1`: once a second, log the whole PiP state
        // machine (controller flags, adapter latches, window/panel state).
        if Self.debugKnob("pip-probe") != nil {
            let probe = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let session = self.nativeSession else { return }
                    guard let win = await session.window else { return }
                    self.log.notice("PIPPROBE \(win.debugPiPState(), privacy: .public)")
                }
            }
            RunLoop.main.add(probe, forMode: .common)
        }
        let pipAfter = Self.debugKnob("pip-after").flatMap(Double.init)
        let quitAfter = Self.debugKnob("quit-after").flatMap(Double.init)
        let returnAfter = Self.debugKnob("return-after").flatMap(Double.init)
        let closeAfter = Self.debugKnob("pip-close-after").flatMap(Double.init)
        let againAfter = Self.debugKnob("pip-again-after").flatMap(Double.init)
        log.notice("DEBUG automation armed: stream host~=\(hostMatch, privacy: .private) pipAfter=\(pipAfter ?? -1) quitAfter=\(quitAfter ?? -1)")

        // Give discovery/host-load a beat, then select + stream.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            guard let host = self.hosts.first(where: {
                $0.name.localizedCaseInsensitiveContains(hostMatch)
                    || ($0.customName?.localizedCaseInsensitiveContains(hostMatch) ?? false)
                    || ($0.localAddress?.localizedCaseInsensitiveContains(hostMatch) ?? false)
                    || ($0.manualAddress?.localizedCaseInsensitiveContains(hostMatch) ?? false)
            }) else {
                self.log.error("DEBUG automation: no host matching '\(hostMatch, privacy: .private)' among \(self.hosts.map(\.name), privacy: .private)")
                return
            }
            self.log.notice("DEBUG automation: selecting \(host.name, privacy: .private) (\(host.apps.count) apps) and streaming default")
            self.selectHost(host)
            // `--debug-open-in-pip=1`: as the menu bar's "... in Picture in Picture".
            if Self.debugKnob("open-in-pip") != nil { self.pictureInPictureLaunchRequestedAt = Date() }
            self.streamDefaultApp()
            // `--debug-close-main=1`: as after a login-item launch - no main window.
            if Self.debugKnob("close-main") != nil {
                for window in NSApp.windows where window.identifier?.rawValue == "main" { window.close() }
            }
            self.armDebugPiPAndQuit(pipAfter: pipAfter, returnAfter: returnAfter, closeAfter: closeAfter,
                                    againAfter: againAfter, quitAfter: quitAfter)
        }
    }

    private func runDebugCycle(spec: String, rounds: Int, hide: Bool) {
        let steps: [(match: String, seconds: Double)] = spec.split(separator: ",").compactMap { part in
            let kv = part.split(separator: ":", maxSplits: 1)
            guard kv.count == 2, let seconds = Double(kv[1]) else { return nil }
            return (String(kv[0]), seconds)
        }
        guard !steps.isEmpty, rounds > 0 else { return }
        Diag.notice("CYCLE armed: \(steps.count) step(s) x \(rounds) rounds, hide \(hide)", "Debug")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            for round in 1...rounds {
                for (index, step) in steps.enumerated() {
                    guard let self else { return }
                    guard let host = self.debugHost(matching: step.match) else {
                        Diag.error("CYCLE: no host matching \(step.match)", "Debug")
                        return
                    }
                    Diag.notice("CYCLE \(round)/\(rounds) step \(index): start \(host.displayName)", "Debug")
                    self.selectHost(host)
                    self.streamDefaultApp()
                    let live = await self.debugWait(seconds: 45) { phase in
                        if case .streaming = phase { return true }
                        if case .error = phase { return true }
                        return false
                    }
                    let phase = self.streamPhase
                    if live, case .streaming = phase {
                        let dwell = step.seconds * Double.random(in: 0.5...1.0)
                        if hide, Bool.random() {
                            try? await Task.sleep(for: .seconds(dwell / 2))
                            Diag.notice("CYCLE hide", "Debug")
                            NSApp.hide(nil)
                            try? await Task.sleep(for: .seconds(3))
                            NSApp.unhide(nil)
                            Diag.notice("CYCLE unhide", "Debug")
                            try? await Task.sleep(for: .seconds(dwell / 2))
                        } else {
                            try? await Task.sleep(for: .seconds(dwell))
                        }
                        Diag.notice("CYCLE \(round)/\(rounds) step \(index): stop", "Debug")
                        self.endStream()
                    } else {
                        Diag.notice("CYCLE \(round)/\(rounds) step \(index): not live (\(String(describing: phase))) - cancelling", "Debug")
                        self.cancelConnect()
                    }
                    _ = await self.debugWait(seconds: 30) { phase in
                        switch phase {
                        case .idle, .error: return true
                        default: return false
                        }
                    }
                    let gap: Double = [0.3, 1.0, 2.0, 4.0].randomElement() ?? 2
                    Diag.notice("CYCLE \(round)/\(rounds) step \(index): idle, next in \(gap) s", "Debug")
                    try? await Task.sleep(for: .seconds(gap))
                }
            }
            Diag.notice("CYCLE done: \(rounds) rounds", "Debug")
        }
    }

    /// `--debug-latency=<x,y,w,h>` (normalized region, origin top-left) with
    /// `--debug-stream`: once live, press Square `--debug-latency-count` times
    /// (default 40) and log press -> first changed decoded frame in the region
    /// (`--debug-latency-threshold`, mean |dLuma|, default 6). `--debug-combo=
    /// <name>=<step>,<step>...` (step = buttons joined by +, then :ms, e.g.
    /// `down:50,down+right:50,right+square:80`) sends it `--debug-combo-repeats`
    /// times (default 5). `--debug-latency-dump=<dir>` saves PNGs of the frames.
    /// `--debug-quit-after` still applies.
    private func armLatencyProbeIfRequested() {
        let regionSpec = Self.debugKnob("latency")
        let comboSpec = Self.debugKnob("combo")
        guard regionSpec != nil || comboSpec != nil else { return }
        let probe = LatencyProbe.shared
        if let regionSpec {
            let v = regionSpec.split(separator: ",").compactMap { Double($0) }
            if v.count == 4 { probe.region = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
        }
        if let t = Self.debugKnob("latency-threshold").flatMap(Double.init) { probe.threshold = t }
        LatencyProbe.armed = true
        let count = Self.debugKnob("latency-count").flatMap(Int.init) ?? 40
        let repeats = Self.debugKnob("combo-repeats").flatMap(Int.init) ?? 5
        let dumpDir = Self.debugKnob("latency-dump")
        if let dumpDir { try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true) }
        Diag.notice("LATENCY probe armed: region \(regionSpec ?? "-") combo \(comboSpec ?? "-")", "Debug")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let live = await self.debugWait(seconds: 90) { phase in
                if case .streaming = phase { return true }
                return false
            }
            guard live, let session = self.nativeSession else {
                Diag.error("LATENCY: the stream never went live", "Debug")
                return
            }
            let backend = await session.backend
            // `--debug-latency-delay=<sec>`: start after this (e.g. once PiP is up).
            if let delay = Self.debugKnob("latency-delay").flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(delay))
            }
            // `--debug-latency-prep=<steps>` (combo syntax without the name):
            // e.g. walk into the corner so the character sits at a fixed spot.
            if let prep = Self.debugKnob("latency-prep"), let parsed = Self.parseCombo("prep=\(prep)") {
                await probe.runSteps(backend: backend, steps: parsed.steps)
                try? await Task.sleep(for: .milliseconds(800))
            }
            if regionSpec != nil {
                // `--debug-latency-button=triangle+circle` (default square).
                let button = Self.debugKnob("latency-button")
                    .flatMap { Self.parseCombo("b=\($0):1")?.steps.first?.buttons } ?? StreamProtocol.X_FLAG
                await probe.runLatency(backend: backend, presses: count, button: button, dumpDir: dumpDir)
            }
            if let comboSpec, let parsed = Self.parseCombo(comboSpec) {
                await probe.runCombo(backend: backend, name: parsed.name, steps: parsed.steps, repeats: repeats,
                                     dumpDir: dumpDir ?? NSTemporaryDirectory(),
                                     dumpAfterMs: Self.debugKnob("combo-dump-ms").flatMap(Int.init) ?? 400)
            }
            Diag.notice("LATENCY probe done", "Debug")
        }
    }

    /// `name=down:50,down+right:50,right+square:80`
    static func parseCombo(_ spec: String) -> (name: String, steps: [LatencyProbe.Step])? {
        let parts = spec.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let names: [String: Int32] = [
            "up": StreamProtocol.UP_FLAG, "down": StreamProtocol.DOWN_FLAG, "left": StreamProtocol.LEFT_FLAG,
            "right": StreamProtocol.RIGHT_FLAG, "cross": StreamProtocol.A_FLAG, "circle": StreamProtocol.B_FLAG,
            "square": StreamProtocol.X_FLAG, "triangle": StreamProtocol.Y_FLAG, "l1": StreamProtocol.LB_FLAG,
            "r1": StreamProtocol.RB_FLAG, "none": 0,
        ]
        var steps: [LatencyProbe.Step] = []
        for item in parts[1].split(separator: ",") {
            let kv = item.split(separator: ":")
            guard kv.count == 2, let ms = Int(kv[1]) else { return nil }
            var buttons: Int32 = 0
            for b in kv[0].split(separator: "+") {
                guard let flag = names[String(b)] else { return nil }
                buttons |= flag
            }
            steps.append(LatencyProbe.Step(buttons: buttons, ms: ms))
        }
        return (String(parts[0]), steps)
    }

    /// Poll the stream phase every 100 ms until `done` says so; false on timeout.
    private func debugWait(seconds: Double, until done: (StreamPhase) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done(streamPhase) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Poll for the stream to go live, then schedule the PiP + return + quit
    /// actions relative to that moment (connect time is variable).
    private func armDebugPiPAndQuit(
        pipAfter: Double?, returnAfter: Double?, closeAfter: Double?, againAfter: Double?, quitAfter: Double?
    ) {
        var fired = false
        let start = Date()
        let poll = Timer(timeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            // Give up after 30s of not reaching streaming.
            if Date().timeIntervalSince(start) > 30 {
                self.log.error("DEBUG automation: stream never reached .streaming within 30s (phase=\(String(describing: self.streamPhase), privacy: .private))")
                t.invalidate(); return
            }
            guard self.streamPhase == .streaming, !fired else { return }
            fired = true
            t.invalidate()
            self.log.notice("DEBUG automation: stream is live")
            if let pipAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + pipAfter) { [weak self] in
                    self?.log.notice("DEBUG automation: entering Picture in Picture")
                    self?.enterPictureInPicture()
                }
                if let returnAfter {
                    DispatchQueue.main.asyncAfter(deadline: .now() + pipAfter + returnAfter) { [weak self] in
                        self?.log.notice("DEBUG automation: returning from Picture in Picture")
                        self?.resumeStreamWindow()
                    }
                }
                if let closeAfter {
                    DispatchQueue.main.asyncAfter(deadline: .now() + pipAfter + closeAfter) { [weak self] in
                        self?.log.notice("DEBUG automation: closing Picture in Picture (window stays hidden)")
                        Task { @MainActor [weak self] in
                            guard let win = await self?.nativeSession?.window else { return }
                            win.pictureInPicture.stop()
                        }
                    }
                }
                if let againAfter {
                    DispatchQueue.main.asyncAfter(deadline: .now() + pipAfter + againAfter) { [weak self] in
                        self?.log.notice("DEBUG automation: entering Picture in Picture again")
                        self?.enterPictureInPicture()
                    }
                }
            }
            if let quitAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) { Self.terminateFromRunLoop() }
            }
        }
        RunLoop.main.add(poll, forMode: .common)
    }
}
