//
//  AppModel.swift
//
//  ObservableObject that owns the UI's view of paired hosts, quality
//  settings, pairing state, and stream lifecycle. This file is the class
//  core (published properties + orchestration). The split is:
//
//    * Models/Host.swift      - Host, LibraryApp, QualityPreset,
//                               HotkeyChord, HostLiveStatus
//    * AppModel+Defaults.swift - the typed UserDefaults read helpers `init()`
//                               loads settings through
//    * HostsStore.swift       - UserDefaults read/write of the host list,
//                               moonlight-qt migration, unpair/retrust
//    * QualityCalculator.swift - bitrate/resolution/fps recommendation logic
//    * HostStatusPoller.swift - periodic readiness-chip polling Task
//

import Foundation
import AppKit
import GameController
import SwiftUI
import Observation
import ServiceManagement
import os.log

// MARK: - Observation
//
// `@Observable`'s tracking is property-granular: SwiftUI only rebuilds the
// views that actually read a changed property. There is no manager-wide
// `objectWillChange.send()` hammer; views that compute off non-observed
// global state (e.g. NSScreen.main) hook the `displayInfoRevision`
// sentinel below, which ticks when the screen-parameter notification
// fires.
@MainActor
@Observable
final class AppModel {

    @ObservationIgnored let log = Logger(
        subsystem: "io.ugfugl.Glimmer", category: "AppModel")

    /// True only while `init()` restores persisted settings.
    ///
    /// Load-bearing, and not for the reason Swift's rules suggest: `@Observable`
    /// rewrites the stored properties below into COMPUTED ones, so their
    /// `willSet` / `didSet` bodies DO run inside `init`. ("Property observers
    /// are not called in an initializer" holds only for genuinely stored
    /// properties.) Without this latch, restoring `qualityPreset = .custom`
    /// fired the prefill in its `willSet`, which wrote the OLD preset's
    /// panel-native numbers into `customWidth` / `customHeight` / `customFPS` -
    /// through their own didSets, so they were PERSISTED over the user's saved
    /// resolution a few lines before `init` got round to loading it. The
    /// symptom was the reported one: pick a resolution, relaunch, and it is the
    /// display's native size again.
    @ObservationIgnored var isRestoringDefaults = false

    // Hosts
    var hosts: [Host] = []
    var selectedHost: Host?

    /// Box art for the launcher's app tiles, fetched from the host and cached
    /// on disk. Owned here so one store serves every view.
    let artwork = AppArtworkStore()

    // Stream lifecycle
    var isStreaming = false {
        // The app is `.regular` for as long as a stream is live - see
        // AppDelegate.refreshActivationPolicy for why (Stage Manager). Applied
        // a beat LATER, not here: the menu-bar click that starts a stream
        // calls NSApp.activate() right after this flips, and AppKit drops an
        // activation issued in the same turn as a policy change - the click's
        // grant was wasted, the window never became key, and GameController
        // (which delivers only to the active app) went quiet: the "controller
        // does nothing but the PS button" report of 2026-09-12. Activating
        // FIRST, while still .accessory, is granted; the app stays active
        // through the flip that follows. StreamWindow.show() refreshes too,
        // so a resume faster than this delay is still regular by the time
        // its window orders in.
        didSet {
            guard isStreaming != oldValue else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { AppDelegate.refreshActivationPolicy() }
            }
        }
    }
    /// Active native session, retained while streaming.
    @ObservationIgnored var nativeSession: StreamSession?

    /// The app requested for this session. Observable so the menu bar updates
    /// without relying on last-played defaults or a paused host-status poller.
    var activeStreamApp: LibraryApp?

    // Quality
    // Default `.matchDisplay` (panel-native resolution + refresh) - the option
    // shown at the top of the preset list. An explicit choice is persisted by
    // the didSet below and read back (with the legacy-preset remap) in init().
    // (HiDPI was removed from the Resolution picker; init() migrates anyone
    // still on it to Match display.)
    var qualityPreset: QualityPreset = QualityPreset.defaultPreset {
        willSet {
            // Restoring the saved preset is not a user switching presets - see
            // `isRestoringDefaults`, without which this prefill overwrote the
            // saved Custom resolution during launch.
            guard !isRestoringDefaults else { return }
            // When the user switches from a preset to Custom, prefill the custom
            // values with the preset's effective numbers so they're not surprised
            // by a sudden 1920x1080 reset.
            if newValue == .custom && qualityPreset != .custom {
                let snapshot = effectiveValuesForPreset(qualityPreset)
                customWidth = snapshot.width
                customHeight = snapshot.height
                customFPS = snapshot.fps
            }
        }
        didSet {
            guard !isRestoringDefaults else { return }
            // The preset's OWN persistence lives here, not in
            // persistQualitySettings(). That recompute runs on paths the user
            // never touched - launch bootstrap, every display-parameter change -
            // and its unconditional write re-stamped the key with whatever the
            // load had decoded, so a raw value the decoder didn't recognise was
            // overwritten before it could ever be migrated (see
            // `QualityPreset.migrated(fromPersistedRawValue:)`). The
            // `isRestoringDefaults` guard above is what makes that true: under
            // @Observable a didSet is NOT suppressed during init(), so only a
            // real change - which is only ever the Settings picker - reaches
            // UserDefaults now.
            UserDefaults.standard.set(qualityPreset.rawValue, forKey: "qualityPreset")
            persistQualitySettings()
            saveSelectedHostStreamSettings()
        }
    }

    // Custom overrides (used only when qualityPreset == .custom)
    var customWidth: Int = 1920 {
        didSet {
            UserDefaults.standard.set(customWidth, forKey: "customWidth")
            if qualityPreset == .custom { persistQualitySettings() }
            saveSelectedHostStreamSettings()
        }
    }
    var customHeight: Int = 1080 {
        didSet {
            UserDefaults.standard.set(customHeight, forKey: "customHeight")
            if qualityPreset == .custom { persistQualitySettings() }
            saveSelectedHostStreamSettings()
        }
    }
    /// The refresh a stream asks for - the Frame rate picker's number, and the
    /// only source of it since "Match display" was removed. Applies under every
    /// preset; the preset only decides the SIZE.
    var customFPS: Int = 60 {
        didSet {
            UserDefaults.standard.set(customFPS, forKey: "customFPS")
            persistQualitySettings()
            saveSelectedHostStreamSettings()
        }
    }
    /// Bitrate: derived (the measured-anchor / Moonlight-table recommendation
    /// that follows resolution and refresh on its own) or the user's number.
    /// The recommendation is still what the slider shows while automatic, so
    /// switching it off starts from a sensible value.
    var bitrateAuto: Bool = true {
        didSet {
            guard !isRestoringDefaults else { return }
            UserDefaults.standard.set(bitrateAuto, forKey: "bitrateAuto")
            // Turning automatic OFF adopts what the disabled slider was already
            // showing, snapped to its nearest stop, so the readout and the
            // thumb agree and neither jumps as the switch flips. Seeding only
            // when the key had never been written (the first cut) meant a stale
            // manual number from months ago snapped back instead.
            if !bitrateAuto {
                manualBitrateMbps = BitrateSlider.stopsMbps[
                    BitrateSlider.nearestStopIndex(mbps: recommendedBitrateMbpsNow,
                                                   maxMbps: BitrateSlider.stopsMbps.last ?? 300)]
            }
            persistQualitySettings()
            saveSelectedHostStreamSettings()
        }
    }
    /// The bitrate sent when `bitrateAuto` is off, in Mbps. Verbatim on the
    /// wire (no codec discount - the user asked for this number).
    var manualBitrateMbps: Int = 20 {
        didSet {
            UserDefaults.standard.set(manualBitrateMbps, forKey: "manualBitrateMbps")
            persistQualitySettings()
            saveSelectedHostStreamSettings()
        }
    }
    /// HDR for every preset (the key keeps its Custom-era name so existing
    /// installs carry their choice forward).
    var customHDR: Bool = true {
        didSet {
            UserDefaults.standard.set(customHDR, forKey: "customHDR")
            persistQualitySettings()
            saveSelectedHostStreamSettings()
        }
    }

    /// Connection lifecycle published from the native engine. Drives the
    /// connect-banner, the StreamButton role, and the ReadinessChip's
    /// transitional state. See `StreamPhase` for the case set.
    var streamPhase: StreamPhase = .idle

    var activeStreamHostID: String?
    /// A handshake or failed launch is not streaming history.
    var activeStreamHasVideo = false

    /// True when a stream is running but its window has been orderOut'd
    /// because the user Cmd-Tabbed away. The launcher UI shows a "Back to
    /// stream" affordance while this is true. Set by the StreamWindow's
    /// resign/become-key observers via callbacks on this manager.
    var nativeStreamBackgrounded: Bool = false {
        // Headless while the stream lives only in Picture in Picture.
        didSet { if oldValue != nativeStreamBackgrounded { AppDelegate.refreshActivationPolicy() } }
    }

    /// Bring the stream window back from the background. Called by the
    /// launcher's "Back to stream" CTA when nativeStreamBackgrounded is true.
    public func resumeStreamWindow() {
        Task { [weak self] in
            await self?.nativeSession?.resumeWindow()
        }
    }
    var nativeStreamError: String? {
        // A newer failure must never inherit an older one's "just a dropped
        // connection" label - each failure re-earns it via markStreamInterruption -
        // nor its machine: whoever sets the sentence names the machine after.
        didSet {
            interruptedStreamHost = nil
            streamErrorHostID = nil
            streamErrorRecovered = false
        }
    }
    /// The machine in `nativeStreamError` has answered again since. Its status
    /// goes back to what it is now; the sentence about what happened stays
    /// until it is dismissed, a stream starts, or it ages out.
    var streamErrorRecovered = false
    /// Which machine `nativeStreamError` is about. Its page shows the
    /// sentence under the Stream row, and its status reads "needs attention";
    /// another machine's page and status are left alone. Set AFTER the error
    /// (setting the error clears it).
    var streamErrorHostID: String?
    /// Set when `nativeStreamError` describes a dropped connection (sleep, a
    /// Wi-Fi change, the host going away) rather than something the user must
    /// fix. Observed: it decides whether the menu bar shows the warning triangle.
    var interruptedStreamHost: (id: String, failedAt: Date)?

    /// Effective HDR-active state from the native engine. True only when the
    /// host signalled HDR mode AND the bitstream is 10-bit AND the Metal
    /// layer is fully configured for PQ/HLG EDR output. Drives the "HDR"
    /// chip in the stream UI.
    var nativeHDRActive: Bool = false

    /// The active stream's negotiated format, mirrored from the decoder for the
    /// menu-bar Stream section. Zero width means "not known yet" (before the
    /// first decoder setup) or "not streaming"; the menu hides the section then.
    var activeStreamWidth: Int = 0
    var activeStreamHeight: Int = 0
    var activeStreamFps: Int = 0

    /// Brief "Stream ended" toast on the launcher. Flipped on whenever a
    /// stream session ends cleanly (regardless of whether the user quit
    /// via hotkey, the host disconnected, or an error occurred); the
    /// ContentView toast auto-dismisses after ~2s by clearing this back
    /// to false on its own timer. Lives here so any view in the launcher
    /// can react to it - the stream window itself fades independently
    /// (see StreamWindow.close()).
    var streamEndedToastVisible: Bool = false

    /// Receipt for the most recently ENDED session - nil when the last
    /// attempt never went live or ran under the stash threshold. Assigned in
    /// the teardown cleanup right before `streamEndedToastVisible` flips so
    /// the toast's first render already carries its "2h 12m · 12 ms median"
    /// line. Persistence contract: AppModel+SessionReceipt.swift.
    var lastSessionReceipt: SessionReceipt?

    /// Always-on route monitor for the SELECTED host (the readiness chip's
    /// quiet bolt / Wi-Fi glyph). Deliberately independent of the gate-on
    /// telemetry probe - see AppModel+HostRoute.swift. Re-pointed by
    /// the launcher via `refreshHostRoute()` as the selection changes.
    let hostRoute = HostRouteMonitor()

    /// Latest reachability + activity snapshot for the selected host. Drives
    /// the HostHero readiness chip ("Ready · 12 ms", "Streaming Helldivers 2",
    /// "Asleep"). `nil` until the first poll completes after selection. Always
    /// keyed by the selected host's id - see `liveStatusForSelected` for the
    /// safe read accessor used by the UI.
    var hostLiveStatus: HostLiveStatus?

    /// Every machine's last online check, by host id: the sidebar's dots.
    /// Kept here, not in the Servers page, so a tab switch or a closed
    /// window doesn't send them back to grey (see recordReachability).
    var hostReachability: [String: HostReachabilitySample] = [:]

    /// Set when a launch would TAKE OVER a session already running on the host
    /// (someone else streaming, not ours). The launcher binds a confirmation
    /// dialog to this; confirming calls `stream(app:on:)`, cancelling clears it.
    /// nil = no takeover pending (the common case streams straight through).
    var pendingTakeover: PendingTakeover?
    struct PendingTakeover: Equatable {
        let app: LibraryApp
        let host: Host
        let occupantApp: String
    }

    var showStreamStats: Bool = false {
        didSet { UserDefaults.standard.set(showStreamStats, forKey: "showStreamStats") }
    }

    /// The STREAM's own output volume (0...1, 0 = silent) - not the Mac's: it
    /// scales decoded game audio at our player node and nothing else.
    /// Persists. AppModel+StreamAudio.swift owns the rest of this feature.
    var streamVolume: Double = AppModel.loadStreamVolume() {
        didSet {
            guard !isRestoringDefaults else { return }
            UserDefaults.standard.set(streamVolume, forKey: "streamVolume")
            applyStreamVolume()
        }
    }

    /// The overlay's shape, fixed rather than configured. It answers one
    /// question - "is my stream OK right now" - and a corner picker, a row-set
    /// picker and eight threshold steppers were a preferences panel bolted to
    /// a three-line readout. The real diagnostic surface is the telemetry
    /// exporter (TelemetryExporter.swift), which records far more than the
    /// overlay can show and is meant to be read by a machine.
    ///
    /// Top-left is where the overlay has always sat; Minimal is render fps,
    /// latency and bitrate; the thresholds are the shipped defaults.
    let streamStatsCorner = StatsOverlayCorner.topLeft
    let effectiveStatsRows = StatsOverlayDefaults.minimalRows
    let statsThresholds = StatsThresholds.default

    /// The in-stream chords: leave (\u2303\u2325Q), stats overlay (\u2303\u2325S), Picture in
    /// Picture (\u2303\u2325P). Fixed rather than rebindable - the four recorder rows in
    /// Settings were their only writers, and a capsule apiece to re-spell
    /// chords nobody re-spells was more interface than the feature earned.
    /// The engine still reads them through providers (see
    /// AppModel+Streaming.swift), so moving one is a one-line edit to the
    /// `HotkeyChord.default*` constant it names.
    let quitHotkey = HotkeyChord.defaultQuit
    let statsHotkey = HotkeyChord.defaultStats
    let pipHotkey = HotkeyChord.defaultPiP
    /// The menu bar's "... in Picture in Picture": the next stream opens
    /// straight into PiP - no stream window, no app switch. One-shot, and
    /// stale after a minute so a launch that never got as far as its window
    /// can't turn a later, ordinary one into PiP.
    var pictureInPictureLaunchRequestedAt: Date?
    /// "Switch PC" while streaming: started by the old stream's cleanup.
    var pendingHostSwitch: PendingHostSwitch?
    /// The live stream's identity (AppModel+StreamRouting): only its events
    /// and callbacks move AppModel's live state.
    @ObservationIgnored var currentStreamToken: UUID?
    /// Waking a PS5 before a switch to it (AppModel+Streaming.switchHost).
    @ObservationIgnored var switchWakeTask: Task<Void, Never>?
    /// A PS5 stream's first step - finding and waking the console - while it
    /// runs. There is no session yet then, so stopping the attempt is
    /// cancelling this.
    @ObservationIgnored var streamPreflightTask: Task<Bool, Error>?
    /// The PC being asked what it runs before a stream starts (the takeover
    /// check in requestStream). Loading already, before streamPhase says so:
    /// the menu bar spins from the click, not from the connect - a PC that
    /// doesn't answer takes the check ~8 s.
    var streamCheckHostID: String?
    /// A stream just ended and the server hasn't been asked what it runs
    /// yet (the poller waits out the host's /cancel first): the menu bar
    /// spins instead of going blank until that answer, or 12 s, says what
    /// it shows next.
    var awaitingStatusAfterStream = false
    /// A stream setting was changed in the menu during this stream, so the
    /// menu says it applies to the next one. Cleared when a stream ends.
    @ObservationIgnored var streamSettingsChangedMidStream = false
    /// `--debug-spinner=<seconds>`: the menu bar spinner held on, for demo
    /// recordings of it (a real connect shows it for well under a second).
    var debugHoldsSpinner = false
    @ObservationIgnored var awaitingStatusAfterStreamToken: UUID?
    /// That check's task, and the token that tells its end from a newer one's.
    @ObservationIgnored var streamCheckTask: Task<Void, Never>?
    @ObservationIgnored var streamCheckToken: UUID?
    /// Wake & Connect waiting for the woken PC's Sunshine to answer before it
    /// starts the stream (AppModel+Power) - loading, for the menu bar.
    var powerWaitHostID: String?
    /// The user stopped the connect in flight (AppModel+Streaming).
    @ObservationIgnored var connectCancelRequested = false
    /// The session's start() while it runs (the connect). Cancelled along
    /// with a stop, so its control requests abort instead of timing out.
    @ObservationIgnored var streamStartTask: Task<AsyncStream<StreamEvent>, Error>?
    struct PendingHostSwitch {
        /// The machine the next stream opens on. A second Switch PC while
        /// the old stream is still closing changes it (the last pick wins).
        var hostID: String
        var inPictureInPicture: Bool
        /// When the old stream began to close - the switch's clock, so a PS5
        /// that took its time waking doesn't use it up first.
        var requestedAt: Date
    }
    nonisolated static let pictureInPictureLaunchWindowSeconds: TimeInterval = 60
    func consumePictureInPictureLaunch() -> Bool {
        defer { pictureInPictureLaunchRequestedAt = nil }
        guard let at = pictureInPictureLaunchRequestedAt else { return false }
        return Date().timeIntervalSince(at) < Self.pictureInPictureLaunchWindowSeconds
    }
    /// Force macOS Game Mode while a stream is live with a Bluetooth controller
    /// (GameModeBoost): it doubles the controller's Bluetooth polling, in full
    /// screen, a window and Picture in Picture alike. Needs Xcode; without it
    /// macOS still turns Game Mode on by itself in full screen.
    var gameModeDuringStreams: Bool = UserDefaults.standard.object(forKey: "gameModeDuringStreams") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(gameModeDuringStreams, forKey: "gameModeDuringStreams")
            GameModeBoost.shared.setEnabled(gameModeDuringStreams)
        }
    }
    /// True while the running stream is showing in the system Picture in
    /// Picture window (the fullscreen window is hidden). Drives the menu-bar
    /// items. Set from the session's PiP edge callback.
    var nativeStreamPictureInPicture: Bool = false {
        didSet { if oldValue != nativeStreamPictureInPicture { AppDelegate.refreshActivationPolicy() } }
    }
    /// The stream is showing only in Picture in Picture: no stream window,
    /// nothing to Cmd-Tab back to. Shimmer runs headless (no Dock icon) then,
    /// so its menu bar menu opens over another app's full screen - a regular
    /// app's status-item menu doesn't (measured on macOS 27.2, 2026-11-16).
    var streamOnlyInPictureInPicture: Bool {
        isStreaming && nativeStreamBackgrounded && nativeStreamPictureInPicture
    }

    /// Pop the running stream out into Picture in Picture (menu bar entry
    /// point). No-op when nothing is streaming.
    public func toggleStreamFullScreen() {
        Task { [weak self] in
            await self?.nativeSession?.toggleFullScreen()
        }
    }

    public func enterPictureInPicture() {
        Task { [weak self] in
            await self?.nativeSession?.enterPictureInPicture()
        }
    }

    var captureSysKeys: Bool = false {
        didSet { UserDefaults.standard.set(captureSysKeys, forKey: "captureSysKeys") }
    }
    /// Settings › "Disable mouse input" (also the menu bar's Disable/Enable
    /// Mouse row): nothing from the mouse reaches the host, and the stream
    /// never grabs or hides the pointer - so controller-only play can Cmd-Tab
    /// in and out without the pointer getting trapped. Pushed to the running
    /// stream. Off by default.
    var mouseInputDisabled: Bool = false {
        didSet {
            UserDefaults.standard.set(mouseInputDisabled, forKey: "mouseInputDisabled")
            let disabled = mouseInputDisabled
            Task { [weak self] in await self?.nativeSession?.setMouseInputDisabled(disabled) }
        }
    }
    /// Settings › "Quit the game when the stream ends". Off (the default,
    /// and Moonlight's): ending a stream disconnects and the host keeps the
    /// app running, so the next Stream click resumes it. On: every stop
    /// sends /cancel, which terminates the app Sunshine launched.
    var quitAppWhenStreamEnds: Bool = false {
        didSet {
            UserDefaults.standard.set(quitAppWhenStreamEnds, forKey: "quitAppWhenStreamEnds")
            saveSelectedHostStreamSettings()
        }
    }
    /// Settings › "Prefer low audio latency": cap the adaptive audio cushion at
    /// 60 ms on every link. Off by default - the deeper caps are what keep
    /// Wi-Fi and tunnels from crackling. Pushed to the running stream.
    var preferLowAudioLatency: Bool = false {
        didSet {
            UserDefaults.standard.set(preferLowAudioLatency, forKey: "preferLowAudioLatency")
            nativeSession?.audioDecoder.setCushionCeiling(
                preferLowAudioLatency ? AudioDecoder.lowLatencyCushionCeilingMs : nil)
        }
    }
    /// Whether a live stream keeps the Mac and its display awake (always or
    /// never). Pushed to the running session so a change lands mid-stream.
    var keepAwakePolicy: KeepAwakePolicy = KeepAwakePolicy.defaultPolicy {
        didSet {
            UserDefaults.standard.set(keepAwakePolicy.rawValue, forKey: KeepAwakePolicy.defaultsKey)
            Task { [weak self] in await self?.nativeSession?.reconcileKeepAwake() }
        }
    }
    /// Window-mode pointer chord (default ⌃⌥R): a TOGGLE - hands the mouse to
    /// the game for mouselook, and takes it back. The pointer is normally
    /// grabbed by being over the window and freed by a held Esc; this is how
    /// you re-grab without moving the mouse off and back, and how you release
    /// without reaching for Esc. Read live via a provider, like the quit/stats
    let releasePointerHotkey = HotkeyChord.defaultReleasePointer
    /// Live "is any game controller connected" flag, driven by the
    /// `GCControllerDidConnect` / `GCControllerDidDisconnect` observers in
    /// `startLiveRefresh()` and seeded at launch. Because it's an `@Observable`
    /// stored property, SwiftUI views that read it rebuild as controllers come
    /// and go - used to show/hide the controller-permission UI without polling.
    var controllerConnected: Bool = !GCController.controllers().isEmpty

    /// Bumped on a slow timer (`startControllerBatteryPolling`) so the menu-bar
    /// charm's battery READING refreshes while the menu is closed - it comes
    /// from GameController / raw HID, neither observable. Same sentinel trick
    /// as `displayInfoRevision`.
    var controllerBatteryTick: Int = 0

    /// Opt-in raw-HID DualSense reading (Options / Create / Mute buttons that
    /// macOS's GameController framework hides). Requires the Input Monitoring
    /// permission, so it's OFF by default and only enabled explicitly from
    /// Settings ▸ Troubleshooting after an up-front explanation. The key is
    /// also read directly by `DualSenseHID.isEnabled` from non-UI code.
    var rawHIDControllerEnabled: Bool = UserDefaults.standard.bool(forKey: "rawHIDControllerEnabled") {
        didSet {
            UserDefaults.standard.set(rawHIDControllerEnabled, forKey: "rawHIDControllerEnabled")
        }
    }

    /// Reveals the Settings ▸ Diagnostics pane (the single hideable home for the
    /// debug/tuning wires: the Telemetry toggle, the bookmark chord, and the
    /// log/telemetry status line). HIDDEN by default - a normal user never sees it. It's
    /// unhidden by a deliberate option-click on the version line in About (the
    /// Telemetry toggle lives INSIDE this pane, so it can't gate its own reveal -
    /// hence a separate, plainly-debug-only UserDefault). Persisted so a power
    /// user who revealed it keeps it across launches.
    var showDiagnostics: Bool = UserDefaults.standard.bool(forKey: "showDiagnostics") {
        didSet {
            UserDefaults.standard.set(showDiagnostics, forKey: "showDiagnostics")
        }
    }

    /// Opt-in performance telemetry (the gate read by `TelemetryGate.isEnabled`
    /// at stream start). OFF by default; surfaced only in the hidden Diagnostics
    /// pane. Changing it applies on the NEXT stream - the exporter snapshots the
    /// gate when a session starts. Mirrors the raw key `TelemetryGate` reads so
    /// the UI toggle and the engine agree.
    var telemetryEnabled: Bool = UserDefaults.standard.bool(forKey: "telemetryEnabled") {
        didSet {
            UserDefaults.standard.set(telemetryEnabled, forKey: "telemetryEnabled")
        }
    }

    /// Drives the one-time auto-offer alert (on the launcher) when a DualSense
    /// is seen and the user hasn't decided yet. Transient.
    var showRawHIDPrompt = false

    /// Whether the user has answered the auto-offer (Enable or Cancel) - so we
    /// only proactively ask once. They can still flip the Settings toggle.
    var rawHIDPromptAnswered: Bool = UserDefaults.standard.bool(forKey: "rawHIDPromptAnswered") {
        didSet {
            UserDefaults.standard.set(rawHIDPromptAnswered, forKey: "rawHIDPromptAnswered")
        }
    }

    // The raw-HID offer's entry points (maybeOfferRawHID / enableRawHIDFromPrompt /
    // declineRawHIDPrompt) and its explanation copy live in AppModel+RawHID.swift.

    // Pairing
    var pairingInFlight = false

    /// Typed phase of the in-flight pairing handshake. Drives the PairSheet
    /// banner colour, spinner, and result text. `pairingMessage` is the
    /// String-typed read shim for UI code that hasn't migrated.
    var pairingPhase: PairingPhase = .idle

    // `pairingMessage` (the String shim over `pairingPhase`) lives in AppModel+Pairing.swift.

    // Persisted stream config - held here so the UI's "Your next stream"
    // summary stays truthful without depending on moonlight-qt's UserDefaults
    // domain. Internal (not private) so the QualityCalculator extension
    // in QualityCalculator.swift can write them.
    var effectiveWidth: Int = 1920
    var effectiveHeight: Int = 1080
    var effectiveFPS: Int = 60
    var effectiveBitrateKbps: Int = 20_000
    var effectiveHDR: Bool = true

    // Bookkeeping
    @ObservationIgnored weak var appDelegate: AppDelegate?

    /// All NotificationCenter observer tokens we've registered with the
    /// closure form (`addObserver(forName:object:queue:using:)`). Drained
    /// in `deinit` so the manager doesn't leak observer registrations into
    /// NotificationCenter's global table.
    @ObservationIgnored var notificationTokens: [NSObjectProtocol] = []

    /// Background poller for the host readiness chip. Cancelled and
    /// re-spawned on every lifecycle edge (host change, app activation,
    /// stream start/end) - callers go through `restartHostStatusPolling()`
    /// which owns the cancel+respawn dance. Internal so
    /// HostStatusPoller.swift can drive it.
    @ObservationIgnored var hostStatusTask: Task<Void, Never>?

    /// True between NSWorkspace's willSleep and didWake. The chip poller must
    /// not run across a nap: a poll caught mid-exchange when the Mac goes dark
    /// leaves a half-open TLS connection on the host, and Sunshine's single
    /// HTTPS thread blocks on it forever (2026-09-02: 47984 refused for 14h
    /// until a Sunshine restart). `restartHostStatusPolling` is a no-op while
    /// this is set; didWake clears it and re-arms.
    @ObservationIgnored var hostPollingPausedForSleep = false

    /// Observer tokens registered on `NSWorkspace.shared.notificationCenter`
    /// (sleep/wake live there, not on the default center), kept apart from
    /// `notificationTokens` so each is removed from the center that owns it.
    @ObservationIgnored var workspaceTokens: [NSObjectProtocol] = []

    /// Consecutive unreachable TCP probes for the currently-polled host. A
    /// SINGLE timed-out probe degrades the chip to `.unknown` ("Checking...")
    /// rather than asserting `.asleep`; only TWO misses in a row publish
    /// `.asleep`. This is the guard against the post-stream false negative:
    /// right after a session ends the app sends the host `/cancel`, and
    /// Sunshine's HTTP front-end is briefly unresponsive in that window, so a
    /// single probe through that blip would otherwise slander an awake host
    /// (that was streaming <6s ago) as "asleep". Reset to 0 on any reachable
    /// probe. Keyed implicitly to the active poll loop - `restartHostStatusPolling`
    /// resets it when re-arming for a (possibly different) host.
    @ObservationIgnored var hostUnreachableStreak = 0

    /// Per host, the saved address the status poller last reached. A host can
    /// carry a home (local) address and a manual one such as its Tailscale IP;
    /// away from home only the manual one answers. Observed so the route glyph
    /// re-points when it flips.
    var reachableAddressByHost: [String: String] = [:]

    /// Number of consecutive unreachable probes required before the chip
    /// asserts `.asleep`. Sub-threshold misses publish NOTHING (the chip holds
    /// its last-good status - see `publishUnreachable`), so this is purely the
    /// confidence bar for declaring a host down: 3 consecutive 2 s misses
    /// (~30 s) ride out Wi-Fi double-blips and a momentarily busy host without
    /// a false "Asleep", while a genuinely-off box still resolves cleanly.
    static let asleepProbeThreshold = 3

    /// Settle delay before the FIRST chip probe when the poller is re-armed
    /// right after a stream ended. Lets the host's `/cancel`-induced HTTP blip
    /// clear before we probe, so the post-stream poll doesn't race it and
    /// publish a false `.asleep`. Only applied on the stream-end re-arm path
    /// (`restartHostStatusPolling(afterStream: true)`); host-switch / activation
    /// re-arms probe immediately as before.
    static let postStreamPollSettle: TimeInterval = 2.0

    /// Poll interval between /serverinfo refreshes for the selected host's
    /// readiness chip. 10 s is the load-bearing knob from the spec - it's
    /// frequent enough to feel live without hammering the host (Sunshine logs
    /// every /serverinfo) and cheaper than the connection stats overlay's own
    /// per-second cadence.
    static let hostStatusPollSeconds: TimeInterval = 10

    // MARK: Init / lifecycle

    /// Sentinel that `currentDisplayDescription` reads at the top of its
    /// body. `@Observable` can only auto-track stored-property reads - it
    /// can't see through `NSScreen.main` (a global API we don't own), so
    /// the screen-parameter-change notification bumps this revision to
    /// force any view watching `currentDisplayDescription` to recompute.
    var displayInfoRevision: Int = 0

    /// Settings is a page inside the main window (Tailscale's shape), not a
    /// separate Settings scene - so which page is showing is app state.
    var settingsTab: SettingsTab = .computers


    isolated deinit {
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        // Drain NotificationCenter observer tokens we registered with the
        // closure form - without this they outlive the manager and keep the
        // closures (and any captured state) alive in NC's global table.
        // `isolated deinit` keeps the deinit on MainActor (the class's
        // isolation) so we can safely read the MainActor-isolated
        // `notificationTokens` array; Swift 6's default nonisolated deinit
        // refuses that read. NotificationCenter.removeObserver itself is
        // documented thread-safe so the hop is purely a compile-time
        // requirement.
        let tokens = notificationTokens
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        hostStatusTask?.cancel()
    }

    init() {
        // Every line below is a direct property write inside the initializer.
        // NOTE, and this is the trap: those writes DO run the properties'
        // `willSet`/`didSet` bodies. Swift suppresses observers in an
        // initializer only for genuinely STORED properties, and the
        // `@Observable` macro has rewritten every one of these into a computed
        // property backed by the observation registrar. `isRestoringDefaults`
        // is what actually makes this block inert - see its declaration for the
        // resolution-loss bug that ran here for real. The `?? <currentValue>` form keeps the property's
        // declared default whenever the persisted key is absent / out of range /
        // undecodable, which is identical to the prior inline `if let` /
        // `if x > 0` checks but without a branch per key (so the initializer
        // stays under the complexity bar). The persisted-key set is unchanged.
        isRestoringDefaults = true
        defer { isRestoringDefaults = false }
        MenuBarPreferences.forgetRetiredSwitch()
        // The artwork store builds its own paired clients; hand it the same
        // Host → ServerInfo bridge the stream path uses (authoritative cert
        // pin included), rather than letting it reach into AppModel.
        artwork.serverInfoProvider = { [unowned self] host in self.nativeServerInfo(for: host) }
        qualityPreset = Self.persistedQualityPreset() ?? qualityPreset
        // HiDPI is gone from the Resolution picker (see ResolutionChoice.all),
        // so an install on it has no row to show. Convert it to Match display
        // (the panel-native size it most resembles) ONCE - a one-shot marker
        // like the frame-rate drop below, so a later user pick isn't re-stamped.
        // Under isRestoringDefaults the didSet persistence is suppressed, so the
        // new value is written to UserDefaults by hand here.
        if !UserDefaults.standard.bool(forKey: "didDropHiDPIResolution") {
            UserDefaults.standard.set(true, forKey: "didDropHiDPIResolution")
            if qualityPreset == .hidpi {
                qualityPreset = .matchDisplay
                UserDefaults.standard.set(QualityPreset.matchDisplay.rawValue, forKey: "qualityPreset")
            }
        }
        // Width/height/fps are clamped on read: builds whose Quality pane
        // clamped on Return only could persist out-of-range values via a
        // focus-loss commit (0 self-heals via persistedPositiveInt; 1000 Hz
        // did not). Bounds mirror QualityPane's clamp helpers.
        customWidth = min(max(Self.persistedPositiveInt("customWidth") ?? customWidth, 640), 7680)
        customHeight = min(max(Self.persistedPositiveInt("customHeight") ?? customHeight, 480), 4320)
        customFPS = min(max(Self.persistedPositiveInt("customFPS") ?? customFPS, 30), 240)
        // "Match display" is gone from the Frame rate picker (see
        // FrameRateChoice), so an install that was on it has no row to show:
        // convert it to the fixed rate it was ALREADY streaming at, the panel's
        // own refresh. Gated on its own one-shot marker, like the HDR widening
        // above - clearing the old key is not enough, because "key absent +
        // panel preset" is also how a pre-flag install reads, so every later
        // launch would re-migrate and stamp over whatever the user had since
        // picked.
        if !UserDefaults.standard.bool(forKey: "didDropMatchDisplayFrameRate") {
            UserDefaults.standard.set(true, forKey: "didDropMatchDisplayFrameRate")
            let wasMatchingDisplay = UserDefaults.standard.object(forKey: "frameRateMatchesDisplay") == nil
                ? qualityPreset != .custom
                : UserDefaults.standard.bool(forKey: "frameRateMatchesDisplay")
            if wasMatchingDisplay {
                customFPS = FrameRateChoice.migratedRate(displayHz: currentDisplayMaxHz)
            }
            UserDefaults.standard.removeObject(forKey: "frameRateMatchesDisplay")
        }
        bitrateAuto = Self.persistedBool("bitrateAuto") ?? bitrateAuto
        manualBitrateMbps = StreamSizeBounds.clampBitrateMbps(
            Self.persistedPositiveInt("manualBitrateMbps") ?? manualBitrateMbps)
        // One-shot: HDR was hard-coded ON for the panel presets and only asked
        // under Custom, so an install that turned it off under Custom and then
        // went back to a panel preset was still being sent HDR. It applies
        // everywhere now, which would silently DROP HDR for exactly those
        // users - carry them forward on what they were actually seeing.
        if !UserDefaults.standard.bool(forKey: "didWidenHDRToAllPresets") {
            UserDefaults.standard.set(true, forKey: "didWidenHDRToAllPresets")
            if qualityPreset != .custom, Self.persistedBool("customHDR") == false {
                UserDefaults.standard.set(true, forKey: "customHDR")
            }
        }
        customHDR = Self.persistedBool("customHDR") ?? customHDR
        captureSysKeys = Self.persistedBool("captureSysKeys") ?? captureSysKeys
        mouseInputDisabled = Self.persistedBool("mouseInputDisabled") ?? mouseInputDisabled
        quitAppWhenStreamEnds = Self.persistedBool("quitAppWhenStreamEnds") ?? quitAppWhenStreamEnds
        preferLowAudioLatency = Self.persistedBool("preferLowAudioLatency") ?? preferLowAudioLatency
        keepAwakePolicy = KeepAwakePolicy.persisted(
            rawValue: UserDefaults.standard.string(forKey: KeepAwakePolicy.defaultsKey))
        showStreamStats = Self.persistedBool("showStreamStats") ?? showStreamStats
    }

    // MARK: Mute/restore Mac audio

}
