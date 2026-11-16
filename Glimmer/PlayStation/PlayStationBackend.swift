//
//  PlayStationBackend.swift
//
//  The PS5 Remote Play streaming engine: a StreamingBackend over chiaki-ng's
//  libchiaki (third_party/chiaki-ng, AGPL-3.0 + OpenSSL exception). It plugs into
//  the same StreamSession as the Sunshine engine, so the stream window, the
//  decoder, frame pacing, Picture in Picture, audio and controller forwarding are
//  all the shared ones; only the transport differs.
//
//  libchiaki owns its own threads. Its callbacks (video sample, audio, session
//  events) arrive on those threads and are forwarded to the injected sinks and to
//  NativeConnectionEvents exactly the way NativeBackend's receive threads do.
//
//  What the PS5 path does not have: a host app library, keyboard/mouse input (the
//  console takes controller input only), a pairing handshake per connect (the
//  registration keys are reused), and an in-place reconnect (StreamSession ends
//  the session instead - see `supportsInPlaceReconnect`).
//

import Foundation

/// Video settings a PS5 session asks for. The console offers fixed presets.
struct PlayStationStreamOptions: Sendable, Equatable {
    enum Resolution: Int, Sendable { case p720 = 720, p1080 = 1080 }
    enum Codec: Sendable { case h264, h265, h265HDR }

    var resolution: Resolution = .p1080
    var fps: Int = 60
    var codec: Codec = .h265
    /// nil = the preset's bitrate (1080p: 15 Mbps).
    var bitrateKbps: Int?
    /// Keep the bitrate: report no packet loss, so the console never lowers
    /// it (PXPlay's manual mode sends no loss reports at all).
    var holdBitrate = false
    /// Everything else from the PlayStation settings tab.
    var settings = PlayStationSettings.Snapshot()

    /// The console takes 2-100 Mbps (PXPlay's range).
    static func clampBitrate(_ kbps: Int) -> Int { min(100_000, max(2_000, kbps)) }

    var width: Int32 { resolution == .p1080 ? 1920 : 1280 }
    var height: Int32 { resolution == .p1080 ? 1080 : 720 }

    var videoFormat: Int32 {
        switch codec {
        case .h264: return StreamProtocol.VIDEO_FORMAT_H264
        case .h265: return StreamProtocol.VIDEO_FORMAT_H265
        case .h265HDR: return StreamProtocol.VIDEO_FORMAT_H265_MAIN10
        }
    }
}

final class PlayStationBackend: StreamingBackend, @unchecked Sendable {
    static let logCategory = "PlayStation"

    /// Termination codes this backend reports through NativeConnectionEvents.
    /// None of them is in StreamSession.recoverableTerminationCodes or equal to
    /// its dead-peer code, so a PS5 terminate always tears the session down.
    static let terminatedCleanly: Int32 = 0
    static let terminatedWithError: Int32 = 0x5053_0001

    let console: PlayStationConsole
    let options: PlayStationStreamOptions

    private let lock = NSLock()
    private var session: UnsafeMutablePointer<ChiakiSession>?
    /// The Takion version the last session attempt streamed on (lock).
    private var lastAttemptTakionVersion: UInt8 = 0
    private var chiakiLog = UnsafeMutablePointer<ChiakiLog>.allocate(capacity: 1)
    private var hostCString: UnsafeMutablePointer<CChar>?
    /// +1 on self while libchiaki holds our pointer as callback context.
    private var retainedSelf: Unmanaged<PlayStationBackend>?
    private var videoSink: VideoSink?
    private var audioSink: NativeAudioSink?
    private var events: NativeConnectionEvents?
    private var connected = false
    private var stopped = false
    private var quitMessage: String?
    /// The last QUIT was "Remote Play is already in use".
    private var quitInUse = false
    /// The last QUIT was a network failure before the session came up
    /// (refused / no answer), which a console just woken often gives.
    private var quitTransient = false
    private let connectSignal = DispatchSemaphore(value: 0)

    // Controller state per GameStream controller number. Remote Play takes one
    // controller, so every connected pad is merged into it (buttons OR'd,
    // sticks by largest deflection, motion from the first pad that has any).
    private var pads: [UInt8: ChiakiControllerState] = [:]
    private var touchIDs: [UInt8: [UInt32: Int8]] = [:]
    /// Each pad's attitude, from its gyro and accelerometer (chiaki-ng's
    /// Madgwick tracker). The PS5 reads the pad's orientation from the
    /// controller state, not only the raw rates: without it, tilt and
    /// gyro aiming see a pad that never moves. Under `lock`.
    private var motion: [UInt8: PadMotion] = [:]
    private var lastTriggerTypes: (UInt8, UInt8)?
    /// Chat to the console; the Mute button toggles it (`lock`).
    private var microphone: PS5Microphone?
    private var muteHeld: Set<UInt8> = []
    private var loggedInputFrom: Set<String> = []

    // Video bookkeeping (libchiaki's video thread only).
    private var frameNumber: Int32 = 0
    private var loggedFirstFrame = false
    /// Parameter sets that arrived as a frame of their own (the console sends
    /// VPS/SPS/PPS alone at session start and on a resolution change); they
    /// ride in front of the next frame.
    private var pendingParameterSets: [UInt8] = []
    /// Arrival time of the previous audio frame (libchiaki's thread only).
    private var lastAudioArrivalNanos: UInt64 = 0
    /// Audio arrival jitter, which sizes the haptics buffer (libchiaki's
    /// receive thread only).
    private var audioJitter = ArrivalJitter()
    /// The haptics frames' own arrival gaps (libchiaki's receive thread),
    /// to compare with the audio's: the buffer is sized from the audio today.
    private var hapticsJitter = ArrivalJitter()
    private var lastHapticsArrivalNanos: UInt64 = 0
    /// The last keyframe request (`lock`), for the 100 ms spacing.
    private var lastIdrRequestNanos: UInt64 = 0
    /// Debug (`PS5.debugDumpHaptics`): every haptics frame as received, for
    /// offline analysis (libchiaki's receive thread only).
    private lazy var hapticsDump: HapticsDump? = HapticsDump.openIfEnabled()
    private var audioFramesSeen = 0
    private var lastHapticsTargetMs: Double = 0

    /// libchiaki hands audio and video over on ONE receive thread. Decoding
    /// inline would hold audio behind every slow video submit (measured: audio
    /// under-runs clustered on PiP enter/return), so each medium gets its own
    /// serial queue, as the Sunshine engine has its own receive threads.
    private let videoQueue = DispatchQueue(label: "Shimmer.PlayStation.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "Shimmer.PlayStation.audio", qos: .userInteractive)

    /// DualSense haptics arrive as a 3 kHz stereo PCM stream (10 ms frames).
    /// With a DualSense on USB they play on its actuators as they are
    /// (`audioHaptics`). Otherwise they become rumble, the way chiaki-ng drives
    /// other pads: each 30 ms the mean amplitude of each side sets that side's
    /// motor. Rumble state is touched on libchiaki's audio thread and on
    /// `hapticsQueue` only.
    private let hapticsQueue = DispatchQueue(label: "Shimmer.PlayStation.haptics", qos: .userInteractive)
    private var hapticsTimer: DispatchSourceTimer?
    private var hapticsSum: (left: UInt64, right: UInt64, frames: Int) = (0, 0, 0)
    private var hapticsActive = false
    private var loggedHaptics = false
    /// The USB DualSense haptics player, while one is open (guarded by `lock`).
    private var audioHaptics: DualSenseHapticsOutput?
    /// We hold the raw-HID writer open for the session (triggers, light bar).
    private var retainedHID = false
    /// The console's intensity settings, as the pad's power-reduction nibbles
    /// (guarded by `lock`). Off: haptics muted / trigger effects ignored.
    private var hapticsNibble: UInt8 = 0
    private var triggerNibble: UInt8 = 0
    /// Haptics frames played on the actuators / how many carried signal (`lock`).
    private var hapticsFrames = (total: 0, active: 0)
    /// Sum of the per-frame peak over frames with signal, and the latest
    /// arrival-gap line (`lock`), for the end-of-haptics summary.
    private var hapticsPeakSum = 0
    private var hapticsGapSummary = "-"

    init(console: PlayStationConsole, options: PlayStationStreamOptions) {
        self.console = console
        self.options = options
        chiakiLog.initialize(to: ChiakiLog())
        PlayStationBackend.initLog(chiakiLog, includeInfo: true)
        Self.ensureLibInit()
    }

    /// libchiaki's process-wide init (crypto, FEC tables, curl). Every entry
    /// point - discovery, registration, sessions - calls this first.
    static func ensureLibInit() { _ = libInitOnce }

    /// Route a ChiakiLog into the app log through the hexdump filter.
    static func initLog(_ log: UnsafeMutablePointer<ChiakiLog>, includeInfo: Bool) {
        var mask = CHIAKI_LOG_ERROR.rawValue | CHIAKI_LOG_WARNING.rawValue
        if includeInfo { mask |= CHIAKI_LOG_INFO.rawValue }
        chiaki_log_init(log, UInt32(mask), { level, msg, _ in
            PlayStationBackend.forwardLog(level: level, msg: msg)
        }, nil)
    }

    deinit {
        chiakiLog.deinitialize(count: 1)
        chiakiLog.deallocate()
        free(hostCString)
    }

    private static let libInitOnce: Void = {
        let err = chiaki_lib_init()
        if err != CHIAKI_ERR_SUCCESS {
            Diag.error("libchiaki init failed: \(String(cString: chiaki_error_string(err)))", logCategory)
        }
    }()

    private static func forwardLog(level: ChiakiLogLevel, msg: UnsafePointer<CChar>?) {
        guard let msg else { return }
        let line = String(cString: msg)
        // libchiaki logs packet hexdumps at INFO/WARNING; keep only prose.
        if line.hasPrefix("offset") || line.range(of: #"^\s*[0-9a-f]+ ( ?[0-9a-f]{2}){1,16}"#, options: .regularExpression) != nil {
            return
        }
        switch level {
        case CHIAKI_LOG_ERROR: Diag.error("chiaki: \(line)", logCategory)
        case CHIAKI_LOG_WARNING: Diag.notice("chiaki: \(line)", logCategory)
        default: Diag.info("chiaki: \(line)", logCategory)
        }
    }

    // MARK: Lifecycle

    func startConnection(server: BackendServerInfo, config: BackendStreamConfig) throws {
        let events = NativeConnectionEvents()
        lock.withLock { self.events = events }
        Diag.notice("PS5: connecting to \(console.nickname) at \(console.address, privacy: .private) "
            + "(\(options.resolution.rawValue)p\(options.fps), \(options.codec))", Self.logCategory)

        events.stageStarting("PS5 session")
        guard let videoSink = lock.withLock({ self.videoSink }) else {
            events.stageFailed("PS5 session", code: -1)
            throw StreamError.sessionFailed(-1)
        }

        var info = ChiakiConnectInfo()
        info.ps5 = true
        hostCString = strdup(console.address)
        info.host = UnsafePointer(hostCString)
        withUnsafeMutableBytes(of: &info.regist_key) { dst in
            dst.copyBytes(from: console.registKey.prefix(dst.count))
        }
        withUnsafeMutableBytes(of: &info.morning) { dst in
            dst.copyBytes(from: console.rpKey.prefix(dst.count))
        }
        chiaki_connect_video_profile_preset(
            &info.video_profile,
            options.resolution == .p1080 ? CHIAKI_VIDEO_RESOLUTION_PRESET_1080p : CHIAKI_VIDEO_RESOLUTION_PRESET_720p,
            options.fps >= 60 ? CHIAKI_VIDEO_FPS_PRESET_60 : CHIAKI_VIDEO_FPS_PRESET_30)
        switch options.codec {
        case .h264: info.video_profile.codec = CHIAKI_CODEC_H264
        case .h265: info.video_profile.codec = CHIAKI_CODEC_H265
        case .h265HDR: info.video_profile.codec = CHIAKI_CODEC_H265_HDR
        }
        if let kbps = options.bitrateKbps { info.video_profile.bitrate = UInt32(kbps) }
        info.video_profile_auto_downgrade = !options.holdBitrate
        info.enable_keyboard = false
        // Present the pad as a DualSense: the console then sends haptics (as
        // audio) and adaptive-trigger effects instead of plain rumble.
        info.enable_dualsense = true
        // A frame FEC can't rebuild: report it and keep decoding (chiaki sends
        // the corrupt-frame report; the console repairs its references), as
        // PXPlay does. Asking for an IDR instead dropped every frame until it
        // came - a visible freeze. The decoder still asks when it must.
        // Debug A/B knobs (defaults keys, all off/new by default):
        // PS5.debugIdrOnFec restores the IDR-and-wait, PS5.debugReorderUs the
        // reorder hold (chiaki's was 16000), PS5.debugDropPermille drops that
        // many per mille of video packets to exercise loss on a clean LAN.
        // PS5.debugTakionVersion 12 stays on chiaki's old fixed Takion v12
        // instead of negotiating v20 (Sony's app's and PXPlay's), for A/B runs.
        let defaults = UserDefaults.standard
        info.enable_idr_on_fec_failure = defaults.bool(forKey: "PS5.debugIdrOnFec")
        let reorderUs = defaults.integer(forKey: "PS5.debugReorderUs")
        let holdUs = reorderUs > 0 ? reorderUs : 4000
        let dropPermille = max(0, min(500, defaults.integer(forKey: "PS5.debugDropPermille")))
        var takionVersion = defaults.integer(forKey: "PS5.debugTakionVersion") == 12 ? 12 : Self.defaultTakionVersion
        shimmer_set_takion_knobs(Int32(holdUs), Int32(dropPermille), Int32(takionVersion))
        if dropPermille > 0 || reorderUs > 0 || info.enable_idr_on_fec_failure || takionVersion != Self.defaultTakionVersion {
            Diag.notice("PS5 debug: drop \(dropPermille)‰ of video packets, reorder hold \(holdUs) us, "
                + "IDR on FEC failure \(info.enable_idr_on_fec_failure), Takion \(takionVersion)", Self.logCategory)
        }
        info.packet_loss_max = options.holdBitrate ? 0 : 0.05
        Diag.notice("PS5: \(options.height)p\(options.fps) \(options.codec == .h265HDR ? "HDR" : "SDR"), "
            + (options.bitrateKbps.map { "\($0 / 1000) Mbps\(options.holdBitrate ? " (held)" : "")" } ?? "preset bitrate"),
            Self.logCategory)

        // Newest frame straight to the screen (VideoDecoder.presentsDirect),
        // unless the PlayStation tab asks for Smooth (the frame pacer).
        if let decoder = videoSink as? VideoDecoder {
            decoder.presentsDirect = options.settings.presentsDirect
        }
        // The decoder is set up before the first frame can arrive.
        let setup = videoSink.setup(videoFormat: options.videoFormat, width: options.width,
                                    height: options.height, redrawRate: Int32(options.fps))
        guard setup == 0 else {
            events.stageFailed("PS5 session", code: setup)
            throw StreamError.sessionFailed(setup)
        }
        videoSink.start()
        if options.codec == .h265HDR {
            // The console sends HDR10 (PQ, BT.2020) from the first frame; there
            // is no host HDR-mode message as on Sunshine, so engage it now.
            events.setHdrMode(true)
            if let decoder = videoSink as? VideoDecoder {
                DispatchQueue.main.async { MainActor.assumeIsolated { decoder.setHDR(enabled: true) } }
            }
        }

        // The console keeps a session busy for a few seconds after the last one
        // ended ("Remote Play is already in use"); wait it out rather than fail
        // a quick reconnect.
        var attempt = 1
        while true {
            let outcome = try runChiakiSession(info: &info, events: events)
            if outcome == .connected { break }
            // The console agreed to Takion 20 and the session still failed:
            // the next attempt stays on 12, which chiaki has always spoken.
            if takionVersion >= 20, lock.withLock({ lastAttemptTakionVersion }) >= 20, attempt < Self.inUseAttempts {
                Diag.error("PS5: the session on Takion 20 failed (\(lock.withLock { quitMessage } ?? "no reason"))"
                    + " - retrying on Takion 12", Self.logCategory)
                takionVersion = 12
                shimmer_set_takion_knobs(Int32(holdUs), Int32(dropPermille), Int32(takionVersion))
                attempt += 1
                lock.withLock { quitMessage = nil }
                if connectSignal.wait(timeout: .now() + .seconds(2)) == .success, lock.withLock({ stopped }) {
                    throw StreamError.sessionFailed(-1)
                }
                continue
            }
            if outcome == .inUse || outcome == .transient, attempt < Self.inUseAttempts {
                let delay = outcome == .inUse ? 3 : 2
                Diag.notice("PS5: " + (outcome == .inUse ? "the console still holds the previous session"
                                                          : "no session yet (\(lock.withLock { quitMessage } ?? "network"))")
                    + " - retrying in \(delay) s (attempt \(attempt + 1) of \(Self.inUseAttempts))", Self.logCategory)
                attempt += 1
                lock.withLock { quitMessage = nil }
                if connectSignal.wait(timeout: .now() + .seconds(delay)) == .success, lock.withLock({ stopped }) {
                    throw StreamError.sessionFailed(-1)
                }
                continue
            }
            let reason = lock.withLock { quitMessage } ?? "the PS5 did not answer within 20 s"
            Diag.error("PS5: connect failed - \(reason)", Self.logCategory)
            events.stageFailed("PS5 session", code: -1)
            stopConnection()
            throw StreamError.hostUnreachable(reason)
        }
        events.stageComplete("PS5 session")
        armControllerFeedback()
        runDebugKeys()
        events.connectionStarted()
    }

    /// ~15 s: the console holds a quit session ~10 s (measured with ps5ctl).
    static let inUseAttempts = 6

    /// The Takion version a session offers unless PS5.debugTakionVersion says
    /// otherwise (libchiaki patch 0002). v20 - Sony's app's and PXPlay's - was
    /// at parity with v12 in live A/B runs (Astro's controller demo: byte-
    /// identical trigger effects, same haptics rate and frame size, video
    /// without loss, fewer audio gaps); a v20 session that fails retries on 12.
    static let defaultTakionVersion = 20

    enum SessionOutcome { case connected, inUse, transient, failed }

    /// One libchiaki session attempt: init, wire callbacks, start, and wait for
    /// CONNECTED or QUIT (20 s). A failed attempt's session is torn down here;
    /// the sinks stay up for the next attempt.
    private func runChiakiSession(info: inout ChiakiConnectInfo,
                                  events: NativeConnectionEvents) throws -> SessionOutcome {
        lock.withLock {
            connected = false
            quitMessage = nil
            quitInUse = false
            quitTransient = false
            lastAttemptTakionVersion = 0
        }
        // Shimmer allocates the session from the headers it compiled against;
        // libchiaki's patches change its layout, so a stale header would
        // corrupt memory. Refuse rather than stream on a mismatch.
        guard MemoryLayout<ChiakiSession>.size == chiaki_shimmer_session_size() else {
            Diag.error("PS5: ChiakiSession is \(MemoryLayout<ChiakiSession>.size) bytes here, "
                + "\(chiaki_shimmer_session_size()) in libchiaki - rebuild (scripts/build-libchiaki.sh)", Self.logCategory)
            events.stageFailed("PS5 session", code: -1)
            throw StreamError.sessionFailed(-1)
        }
        let session = UnsafeMutablePointer<ChiakiSession>.allocate(capacity: 1)
        session.initialize(to: ChiakiSession())
        let err = chiaki_session_init(session, &info, chiakiLog)
        guard err == CHIAKI_ERR_SUCCESS else {
            session.deallocate()
            events.stageFailed("PS5 session", code: Int32(err.rawValue))
            throw StreamError.sessionFailed(Int32(err.rawValue))
        }
        let retained = Unmanaged.passRetained(self)
        let ctx = retained.toOpaque()
        lock.withLock {
            self.session = session
            self.retainedSelf = retained
        }

        chiaki_session_set_event_cb(session, { event, user in
            guard let event, let user else { return }
            Unmanaged<PlayStationBackend>.fromOpaque(user).takeUnretainedValue().handle(event.pointee)
        }, ctx)
        chiaki_session_set_video_sample_cb(session, { buf, size, framesLost, _, user in
            guard let buf, let user else { return false }
            return Unmanaged<PlayStationBackend>.fromOpaque(user).takeUnretainedValue()
                .handleVideo(UnsafeBufferPointer(start: buf, count: size), framesLost: framesLost)
        }, ctx)
        var audio = ChiakiAudioSink()
        audio.user = ctx
        audio.header_cb = { header, user in
            guard let header, let user else { return }
            Unmanaged<PlayStationBackend>.fromOpaque(user).takeUnretainedValue().handleAudioHeader(header.pointee)
        }
        audio.frame_cb = { buf, size, user in
            guard let buf, let user else { return }
            Unmanaged<PlayStationBackend>.fromOpaque(user).takeUnretainedValue()
                .handleAudioFrame(UnsafeRawBufferPointer(start: buf, count: size))
        }
        chiaki_session_set_audio_sink(session, &audio)
        var haptics = ChiakiAudioSink()
        haptics.user = ctx
        haptics.frame_cb = { buf, size, user in
            guard let buf, let user else { return }
            Unmanaged<PlayStationBackend>.fromOpaque(user).takeUnretainedValue()
                .handleHapticsFrame(UnsafeRawBufferPointer(start: buf, count: size))
        }
        chiaki_session_set_haptics_sink(session, &haptics)

        let mic = PS5Microphone(session: session, log: chiakiLog)
        mic.onMutedChange = { muted in DualSenseHID.shared.setMicLED(lit: muted) }
        lock.withLock { microphone = mic }

        let startErr = chiaki_session_start(session)
        guard startErr == CHIAKI_ERR_SUCCESS else {
            tearDownChiakiSession()
            events.stageFailed("PS5 session", code: Int32(startErr.rawValue))
            throw StreamError.sessionFailed(Int32(startErr.rawValue))
        }
        // Block (we run on StreamSession's connect task) until CONNECTED, QUIT,
        // an interrupt, or 20 s.
        _ = connectSignal.wait(timeout: .now() + 20)
        let (isConnected, inUse, transient) = lock.withLock { (connected, quitInUse, quitTransient) }
        // Set once, before BIG; 0 if the attempt never reached the stream connection.
        let spoke = session.pointee.stream_connection.takion.version
        lock.withLock { lastAttemptTakionVersion = spoke }
        if isConnected {
            Diag.notice("PS5: streaming on Takion \(spoke)", Self.logCategory)
            return .connected
        }
        tearDownChiakiSession()
        return inUse ? .inUse : transient ? .transient : .failed
    }

    /// Failures worth another try (PXPlay retries its session request 5 times,
    /// 2 s apart, on an I/O error).
    static let transientQuitReasons: Set<ChiakiQuitReason> = [
        CHIAKI_QUIT_REASON_SESSION_REQUEST_UNKNOWN, CHIAKI_QUIT_REASON_SESSION_REQUEST_CONNECTION_REFUSED,
        CHIAKI_QUIT_REASON_CTRL_CONNECT_FAILED, CHIAKI_QUIT_REASON_CTRL_CONNECTION_REFUSED,
    ]

    /// Stop, join and free the current libchiaki session (sinks untouched).
    private func tearDownChiakiSession() {
        let (session, retained, mic) = lock.withLock {
            () -> (UnsafeMutablePointer<ChiakiSession>?, Unmanaged<PlayStationBackend>?, PS5Microphone?) in
            let s = self.session, r = self.retainedSelf, m = self.microphone
            self.session = nil
            self.retainedSelf = nil
            self.microphone = nil
            return (s, r, m)
        }
        // Capture stops, and the encoder's sender goes, before the session.
        if mic != nil { DualSenseHID.shared.setMicLED(lit: nil) }
        mic?.close()
        if let session {
            chiaki_session_stop(session)
            chiaki_session_join(session)
            chiaki_session_fini(session)
            session.deinitialize(count: 1)
            session.deallocate()
        }
        retained?.release()
    }

    func stopConnection() {
        let (video, audio) = lock.withLock { () -> (VideoSink?, NativeAudioSink?) in
            self.stopped = true
            return (self.videoSink, self.audioSink)
        }
        connectSignal.signal()
        Diag.info("PS5: stopping session", Self.logCategory)
        if options.settings.restWhenStreamEnds, let session = lock.withLock({ connected ? self.session : nil }) {
            // The PlayStation tab's "Put the PS5 to rest": ask before leaving.
            _ = chiaki_session_goto_bed(session)
            Diag.notice("PS5: asked the console to go to rest", Self.logCategory)
            Thread.sleep(forTimeInterval: 0.3)
        }
        tearDownChiakiSession()
        // Let queued frames finish before the sinks are torn down.
        videoQueue.sync {}
        audioQueue.sync {}
        hapticsQueue.sync {
            hapticsTimer?.cancel()
            hapticsTimer = nil
        }
        stopAudioHaptics(reason: "stream ended")
        if lock.withLock({ () -> Bool in defer { retainedHID = false }; return retainedHID }) {
            DualSenseHID.shared.release()
        }
        ControllerHaptics.shared.stopAll(reason: "stream teardown")
        ControllerMotion.shared.stopAll(reason: "stream teardown")
        video?.stop()
        video?.cleanup()
        audio?.cleanup()
    }

    func interruptConnection() {
        let session = lock.withLock { () -> UnsafeMutablePointer<ChiakiSession>? in
            stopped = true
            return self.session
        }
        if let session { chiaki_session_stop(session) }
        connectSignal.signal()
    }

    // MARK: Sinks

    func attachVideoSink(_ sink: VideoSink) { lock.withLock { videoSink = sink } }
    func attachAudioSink(_ sink: NativeAudioSink) { lock.withLock { audioSink = sink } }

    // MARK: Telemetry / control

    func estimatedRtt() -> (rttMs: Double, varianceMs: Double)? {
        lock.withLock {
            guard connected, let session else { return nil }
            return (Double(session.pointee.rtt_us) / 1000.0, 0)
        }
    }

    /// At most one keyframe request per 100 ms (PXPlay's spacing): a burst of
    /// decoder errors asks once, not once per frame, and each IDR the console
    /// sends is a bitrate spike that blurs the picture.
    func requestIdrFrame() {
        let now = DispatchTime.now().uptimeNanoseconds
        let session = lock.withLock { () -> UnsafeMutablePointer<ChiakiSession>? in
            guard now &- lastIdrRequestNanos >= 100_000_000 else { return nil }
            lastIdrRequestNanos = now
            return self.session
        }
        if let session { _ = chiaki_session_request_idr(session) }
    }

    func hdrMetadata() -> HdrMetadata? { nil }
    func launchUrlQueryParameters() -> String { "" }
    func stageName(for stage: Int32) -> String { "PS5 session" }

    /// Measured stream bitrate (Mbps) as libchiaki computes it.
    var measuredBitrateMbps: Double {
        lock.withLock { session?.pointee.stream_connection.measured_bitrate ?? 0 }
    }

    // MARK: libchiaki callbacks

    private func handle(_ event: ChiakiEvent) {
        switch event.type {
        case CHIAKI_EVENT_CONNECTED:
            Diag.notice("PS5: connected to \(console.nickname)", Self.logCategory)
            lock.withLock { connected = true }
            connectSignal.signal()
        case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
            // A console with a login passcode asks for it here. Not supported yet:
            // end the attempt with a message rather than hang.
            Diag.error("PS5: the console asks for its login passcode - not supported yet", Self.logCategory)
            lock.withLock { quitMessage = "the PS5 asks for its login passcode, which Shimmer can't enter yet" }
            interruptConnection()
        case CHIAKI_EVENT_QUIT:
            var message = String(cString: chiaki_quit_reason_string(event.quit.reason))
            if let detail = event.quit.reason_str { message += ": " + String(cString: detail) }
            let isError = chiaki_quit_reason_is_error(event.quit.reason)
            let (wasConnected, wasStopped, events) = lock.withLock { () -> (Bool, Bool, NativeConnectionEvents?) in
                if quitMessage == nil { quitMessage = message }
                quitInUse = event.quit.reason == CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_IN_USE
                quitTransient = Self.transientQuitReasons.contains(event.quit.reason)
                return (connected, stopped, self.events)
            }
            Diag.notice("PS5: session ended - \(message)", Self.logCategory)
            connectSignal.signal()
            // Only a live session that the console (not we) ended is a terminate.
            if wasConnected && !wasStopped {
                events?.connectionTerminated(code: isError ? Self.terminatedWithError : Self.terminatedCleanly)
            }
        case CHIAKI_EVENT_RUMBLE:
            handleRumble(left: event.rumble.left, right: event.rumble.right)
        case CHIAKI_EVENT_TRIGGER_EFFECTS:
            // Trigger effects switched off in the console's settings, or here.
            guard options.settings.adaptiveTriggers,
                  lock.withLock({ triggerNibble }) != Self.intensityOff & 0xF0 else { break }
            let effect = event.trigger_effects
            let left = withUnsafeBytes(of: effect.left) { Array($0) }
            let right = withUnsafeBytes(of: effect.right) { Array($0) }
            let events = lock.withLock { self.events }
            // 0x04 | 0x08: both trigger blocks (DS_EFFECT_RIGHT/LEFT_TRIGGER).
            events?.setAdaptiveTriggers(controller: 0, eventFlags: 0x0C,
                                        typeLeft: effect.type_left, typeRight: effect.type_right,
                                        left: left, right: right)
            let types = (effect.type_left, effect.type_right)
            if lock.withLock({ () -> Bool in
                defer { lastTriggerTypes = types }
                return lastTriggerTypes.map { $0 != types } ?? true
            }) {
                Diag.info("PS5: adaptive triggers L=\(types.0) R=\(types.1)", Self.logCategory)
            }
        case CHIAKI_EVENT_MOTION_RESET:
            // A game re-centred motion: the pad's pose now is "level".
            lock.withLock {
                for (num, var m) in motion {
                    m.recenter()
                    motion[num] = m
                    if var pad = pads[num] {
                        chiaki_orientation_tracker_apply_to_controller_state(&m.tracker, &pad)
                        pads[num] = pad
                    }
                }
            }
            _ = pushPad()
        case CHIAKI_EVENT_LED_COLOR:
            guard options.settings.lightBar else { break }
            let (events, usbHaptics) = lock.withLock { (self.events, audioHaptics != nil) }
            let led = event.led_state
            // GameController's light setter would switch the pad's audio haptics off.
            if usbHaptics {
                DualSenseHID.shared.setLightbar(red: led.0, green: led.1, blue: led.2)
            } else {
                events?.setControllerLED(controller: 0, r: led.0, g: led.1, b: led.2)
            }
        case CHIAKI_EVENT_HAPTIC_INTENSITY, CHIAKI_EVENT_TRIGGER_INTENSITY:
            applyIntensity(event.intensity, haptics: event.type == CHIAKI_EVENT_HAPTIC_INTENSITY)
        default:
            break
        }
    }

    /// One complete Annex-B access unit from libchiaki (already FEC-recovered and
    /// reordered). Decoding happens on `videoQueue`; a decoder that needs an IDR
    /// asks for one from there.
    private func handleVideo(_ frame: UnsafeBufferPointer<UInt8>, framesLost: Int32) -> Bool {
        guard let sink = lock.withLock({ videoSink }) else { return false }
        let hevc = options.codec != .h264
        var bytes = Array(frame)
        if !pendingParameterSets.isEmpty {
            bytes = pendingParameterSets + bytes
            pendingParameterSets = []
        }
        let isIDR = VideoDepacketizer.isIdrFrameStart(bytes, hevc: hevc)
        let data = Data(bytes)
        let buffers = isIDR ? Self.splitParameterSets(data, hevc: hevc) : [DecodeBuffer(kind: .picData, data: data)]
        if isIDR, buffers.last?.data.isEmpty == true {
            // Headers only: hold them for the picture that follows.
            pendingParameterSets = bytes
            return true
        }
        frameNumber &+= 1
        let nowUs = UInt64(DispatchTime.now().uptimeNanoseconds / 1000)
        // 90 kHz capture-style clock from arrival time; never 0.
        let rtpTimestamp = UInt32(truncatingIfNeeded: nowUs * 9 / 100) | 1
        // Latency telemetry (opt-in): a PS5 frame's arrival is its receive and
        // assemble stage, so arrival-to-present is measured as on Sunshine.
        if let tracker = FrameTimingTracker.shared {
            tracker.recordAssembled(rtpTimestamp: rtpTimestamp, frameIndex: frameNumber,
                                    receiveNanos: nowUs * 1000, assembleNanos: nowUs * 1000,
                                    frameBytes: Int32(data.count), isIDR: isIDR)
        }
        let unit = DecodeUnit(
            frameNumber: frameNumber,
            frameType: isIDR ? VideoDepacketizer.FRAME_TYPE_IDR : 0,
            fullLength: Int32(data.count),
            frameHostProcessingLatency: 0,
            receiveTimeUs: nowUs,
            enqueueTimeUs: nowUs,
            presentationTimeUs: nowUs,
            rtpTimestamp: rtpTimestamp,
            hdrActive: options.codec == .h265HDR,
            colorspace: 0,
            buffers: buffers)
        if !loggedFirstFrame {
            loggedFirstFrame = true
            Diag.notice("PS5: first video frame (\(data.count) bytes, \(isIDR ? "IDR" : "P"))", Self.logCategory)
        }
        videoQueue.async { [weak self] in
            if sink.submitDecodeUnit(unit) == StreamProtocol.DR_NEED_IDR {
                self?.requestIdrFrame()
            }
        }
        return true
    }

    private func handleAudioHeader(_ header: ChiakiAudioHeader) {
        guard let sink = lock.withLock({ audioSink }) else { return }
        let channels = Int32(header.channels)
        let opus = OpusConfig(
            sampleRate: Int32(header.rate), channelCount: channels, streams: 1, coupledStreams: 1,
            samplesPerFrame: Int32(header.frame_size), mapping: [0, 1])
        // Channel count in the GameStream audio-configuration encoding the
        // decoder reads (0xCA | count << 8 | mask << 16); the PS5 sends stereo.
        let audioConfig = Int32(gl_make_audio_configuration(Int32(max(channels, 2)), 0x3))
        let result = sink.initialize(audioConfig: audioConfig, opus: opus)
        Diag.notice("PS5: audio \(header.channels) ch \(header.rate) Hz, \(header.frame_size) samples/frame "
            + "(init \(result))", Self.logCategory)
    }

    private func handleAudioFrame(_ opus: UnsafeRawBufferPointer) {
        guard let sink = lock.withLock({ audioSink }) else { return }
        // The console stops sending audio during silence (its home screen is
        // silent). Report arrival gaps the way RtpAudioReceiver does, so the
        // decoder reads a gap as dead air, not as a network under-run.
        let now = DispatchTime.now().uptimeNanoseconds
        let gap: UInt64? = lastAudioArrivalNanos == 0 ? nil : now &- lastAudioArrivalNanos
        lastAudioArrivalNanos = now
        if let gap { tuneHapticsBuffer(gapMs: Double(gap) / 1_000_000) }
        let packet = Data(opus)
        audioQueue.async {
            if let gap {
                if gap >= RtpAudioReceiver.flowResumeGapNanos {
                    sink.notePacketFlowResumed(afterGapMs: Double(gap) / 1_000_000)
                }
                sink.noteArrivalGap(nanos: gap)
            }
            packet.withUnsafeBytes { sink.decodeAndPlay($0) }
        }
    }

    /// Parameter sets (VPS/SPS/PPS) as their own buffers, start codes kept, the
    /// rest of the access unit as one picData buffer - the shape the decoder
    /// rebuilds its format description from on an IDR.
    static func splitParameterSets(_ au: Data, hevc: Bool) -> [DecodeBuffer] {
        let bytes = [UInt8](au)
        var starts: [Int] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append(i > 0 && bytes[i - 1] == 0 ? i - 1 : i)
                i += 3
            } else {
                i += 1
            }
        }
        guard !starts.isEmpty else { return [DecodeBuffer(kind: .picData, data: au)] }
        var params: [DecodeBuffer] = []
        var picData = Data()
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1] : bytes.count
            let header = start + (bytes[start + 2] == 1 ? 3 : 4)
            guard header < end else { continue }
            let nal = au.subdata(in: start..<end)
            let type = hevc ? (bytes[header] >> 1) & 0x3F : bytes[header] & 0x1F
            switch (hevc, type) {
            case (true, 32): params.append(DecodeBuffer(kind: .vps, data: nal))
            case (true, 33), (false, 7): params.append(DecodeBuffer(kind: .sps, data: nal))
            case (true, 34), (false, 8): params.append(DecodeBuffer(kind: .pps, data: nal))
            default: picData.append(nal)
            }
        }
        return params + [DecodeBuffer(kind: .picData, data: picData)]
    }

    // MARK: Haptics

    /// One haptics frame: interleaved Int16 L/R samples. Sum |amplitude| per side.
    private func handleHapticsFrame(_ pcm: UnsafeRawBufferPointer) {
        guard options.settings.haptics != .off else { return }
        let arrival = DispatchTime.now().uptimeNanoseconds
        if lastHapticsArrivalNanos != 0 {
            hapticsJitter.add(gapMs: Double(arrival &- lastHapticsArrivalNanos) / 1_000_000)
        }
        lastHapticsArrivalNanos = arrival
        hapticsDump?.write(arrival: arrival, pcm: pcm)
        if let player = lock.withLock({ audioHaptics }) {
            player.push(pcm)
            noteActuatorFrame(pcm, player: player)
            return
        }
        let samples = pcm.count / 4
        guard samples > 0 else { return }
        var left: UInt64 = 0, right: UInt64 = 0
        for i in 0..<samples {
            left += UInt64(abs(Int32(pcm.loadUnaligned(fromByteOffset: i * 4, as: Int16.self))))
            right += UInt64(abs(Int32(pcm.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self))))
        }
        let meanL = left / UInt64(samples), meanR = right / UInt64(samples)
        hapticsQueue.async { [weak self] in
            guard let self else { return }
            self.hapticsSum.left += meanL
            self.hapticsSum.right += meanR
            self.hapticsSum.frames += 1
            if !self.loggedHaptics, meanL + meanR > 0 {
                self.loggedHaptics = true
                Diag.notice("PS5: first haptics from the console", Self.logCategory)
            }
        }
    }

    /// Every 30 ms: the window's mean amplitude → motor strength (x2, as
    /// chiaki-ng scales it; quiet frames below the floor are silence).
    private func startHapticsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: hapticsQueue)
        timer.schedule(deadline: .now() + .milliseconds(30), repeating: .milliseconds(30))
        timer.setEventHandler { [weak self] in self?.flushHaptics() }
        timer.resume()
        hapticsTimer = timer
    }

    private func flushHaptics() {
        let sum = hapticsSum
        hapticsSum = (0, 0, 0)
        let (left, right) = Self.rumbleStrength(sumLeft: sum.left, sumRight: sum.right, frames: sum.frames)
        let active = left > 0 || right > 0
        guard active || hapticsActive else { return }
        hapticsActive = active
        let events = lock.withLock { self.events }
        // Low-frequency (big) motor on the left, high-frequency on the right,
        // matching the DualSense's left/right actuator sides.
        events?.rumble(controller: 0, lowFreq: left, highFreq: right)
    }

    /// Mean |amplitude| per frame, averaged over a window → 16-bit motor
    /// strength: x2 (chiaki-ng's scale), a floor that treats hiss as silence,
    /// and a minimum that pads which ignore tiny values can still feel.
    static func rumbleStrength(sumLeft: UInt64, sumRight: UInt64, frames: Int) -> (UInt16, UInt16) {
        guard frames > 0 else { return (0, 0) }
        func scale(_ sum: UInt64) -> UInt16 {
            let v = sum * 2 / UInt64(frames)
            guard v > hapticsFloor else { return 0 }
            return UInt16(min(max(v, 1 << 9), UInt64(UInt16.max)))
        }
        return (scale(sumLeft), scale(sumRight))
    }
    static let hapticsFloor: UInt64 = 300

    /// Open the USB DualSense's actuators, or fall back to rumble.
    /// The pad's actuators: over USB through its audio device, over Bluetooth
    /// through its haptics report. Neither (another pad): rumble.
    private func startAudioHaptics(bluetoothWait: Int = 20) {
        guard !lock.withLock({ stopped }) else { return }
        switch options.settings.haptics {
        case .off:
            Diag.info("PS5: haptics off (PlayStation settings)", Self.logCategory)
            return
        case .rumble:
            Diag.info("PS5: haptics play as rumble (PlayStation settings)", Self.logCategory)
            hapticsQueue.async { [weak self] in self?.startHapticsTimer() }
            return
        case .actuators:
            break
        }
        if let player = DualSenseAudioHaptics.start(onLost: { [weak self] in
            self?.restartAudioHaptics(reason: "the DualSense audio device changed")
        }) {
            useActuators(player)
        } else if let player = DualSenseBluetoothHaptics.start(onLost: { [weak self] in
            self?.restartAudioHaptics(reason: "the DualSense left Bluetooth")
        }) {
            useActuators(player)
        } else if bluetoothWait > 0 {
            // The HID reader may still be matching the pad: look again shortly.
            hapticsQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                self?.startAudioHaptics(bluetoothWait: bluetoothWait - 1)
            }
        } else {
            Diag.info("PS5: no DualSense haptics output - haptics play as rumble", Self.logCategory)
            hapticsQueue.async { [weak self] in self?.startHapticsTimer() }
        }
    }

    /// The pad changed transport mid-stream (USB cable in or out): follow it.
    /// It takes a few seconds to come back on Bluetooth, so look for up to 10 s;
    /// rumble covers the gap if it never does.
    private func restartAudioHaptics(reason: String) {
        stopAudioHaptics(reason: reason)
        hapticsQueue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            self?.startAudioHaptics(bluetoothWait: 100)
        }
    }

    private func useActuators(_ player: DualSenseHapticsOutput) {
        let muted = lock.withLock { () -> Bool in
            audioHaptics = player
            return hapticsNibble == Self.intensityOff & 0x0F
        }
        if muted { player.setGain(0) }
        // Over Bluetooth each 0x31 write takes a slot on the link the haptics need.
        // USB: a quarter-second keepalive, so a GameController write that
        // muted the actuators costs at most 250 ms of haptics (a USB report is
        // free); Bluetooth: every 2 s, outside haptics bursts (a link slot).
        let bluetooth = player is DualSenseBluetoothHaptics
        DualSenseHID.shared.setAudioHapticsMode(true, keepAliveEvery: bluetooth ? 2 : 0.25, padFilter: bluetooth)
        Diag.notice("PS5: haptics play on the DualSense's actuators (\(player.deviceName))", Self.logCategory)
    }

    private func stopAudioHaptics(reason: String, fallBackToRumble: Bool = false) {
        guard let player = lock.withLock({ () -> DualSenseHapticsOutput? in
            defer { audioHaptics = nil }
            return audioHaptics
        }) else { return }
        let stats = player.stats
        player.stop()
        DualSenseHID.shared.setAudioHapticsMode(false)
        let (frames, peakSum, gapLine) = lock.withLock { (hapticsFrames, hapticsPeakSum, hapticsGapSummary) }
        let meanPeak = frames.active > 0 ? peakSum / frames.active : 0
        Diag.info("PS5: DualSense haptics stopped (\(reason)); \(frames.active)/\(frames.total) frames with "
            + "signal (mean peak \(meanPeak)) in \(stats.runs) runs (\(stats.cut) cut short), buffer "
            + "\(stats.targetMs) ms; arrival gaps \(gapLine); "
            + "\(DualSenseHID.shared.takeTriggerStats())"
            + ((player as? DualSenseBluetoothHaptics).map { "; Bluetooth: \($0.linkStats)" } ?? ""), Self.logCategory)
        if fallBackToRumble, !lock.withLock({ stopped }) {
            hapticsQueue.async { [weak self] in
                guard let self, self.hapticsTimer == nil else { return }
                self.startHapticsTimer()
            }
        }
    }

    /// Every half second of audio, size the haptics buffer from its jitter.
    private func tuneHapticsBuffer(gapMs: Double) {
        audioJitter.add(gapMs: gapMs)
        audioFramesSeen += 1
        guard audioFramesSeen % 50 == 0, let target = audioJitter.hapticsTargetMs,
              let player = lock.withLock({ audioHaptics }) else { return }
        player.setTarget(ms: target)
        if abs(target - lastHapticsTargetMs) >= 10 {
            lastHapticsTargetMs = target
            Diag.info("PS5: haptics buffer \(Int(target)) ms (audio arrival jitter)", Self.logCategory)
        }
    }

    /// Breadcrumbs for the actuator path: the first frame with signal, then a
    /// summary every 30 s of haptics (frames arrive every 10 ms).
    private func noteActuatorFrame(_ pcm: UnsafeRawBufferPointer, player: DualSenseHapticsOutput) {
        var peak: Int32 = 0
        for i in 0..<(pcm.count / 2) { peak = max(peak, abs(Int32(pcm.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))) }
        let (total, active) = lock.withLock { () -> (Int, Int) in
            hapticsFrames.total += 1
            if peak > 64 { hapticsFrames.active += 1; hapticsPeakSum += Int(peak) }
            return hapticsFrames
        }
        if total % 100 == 0 {
            let line = "haptics \(Self.gapSummary(hapticsJitter)), audio \(Self.gapSummary(audioJitter))"
            lock.withLock { hapticsGapSummary = line }
        }
        if peak > 64, active == 1 {
            Diag.notice("PS5: first haptics from the console (playing on the actuators)", Self.logCategory)
        }
        if total % 3000 == 0 {
            let stats = player.stats
            Diag.info("PS5: haptics \(active)/\(total) frames with signal; buffer \(stats.targetMs) ms, "
                + "\(stats.runs) runs (\(stats.cut) cut short); arrival gaps "
                + "\(lock.withLock { hapticsGapSummary })", Self.logCategory)
        }
    }

    static func gapSummary(_ j: ArrivalJitter) -> String {
        guard let p50 = j.percentile(0.5), let p95 = j.percentile(0.95), let p99 = j.percentile(0.99) else {
            return "- (\(j.count) gaps)"
        }
        return String(format: "p50 %.1f p95 %.1f p99 %.1f ms (%d gaps)", p50, p95, p99, j.count)
    }

    /// Debug: feed `seconds` of a 90 Hz half-scale tone into the haptics path
    /// in 10 ms frames, the console's shape.
    private func playDebugHaptics(seconds: Double) {
        var phase = 0.0
        for n in 0..<Int(seconds * 100) {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10 * n)) { [weak self] in
                var frame = [Int16]()
                for _ in 0..<30 {
                    let v = Int16(sin(phase) * 16_000)
                    frame += [v, v]
                    phase += 2 * .pi * 90 / 3000
                }
                frame.withUnsafeBytes { self?.handleHapticsFrame($0) }
            }
        }
    }

    /// Plain rumble from the console (PS4 games, mostly). With USB haptics on,
    /// it goes through our own report; GameController's would be undone by the
    /// haptics keepalive within a second.
    private func handleRumble(left: UInt8, right: UInt8) {
        let (events, player) = lock.withLock { (self.events, audioHaptics) }
        if let player {
            // While the actuators play the console's haptics, its rumble is a
            // compatibility copy of the same effect. Over Bluetooth a rumble
            // report costs the haptics a link slot and switches the pad to
            // rumble emulation, cutting the haptics off; skip it there
            // (chiaki-ng does the same), and let it through once they go quiet.
            if player is DualSenseBluetoothHaptics, left != 0 || right != 0, DualSenseHID.shared.hapticsBusy {
                if DualSenseHID.shared.isRumbling { DualSenseHID.shared.setRumble(left: 0, right: 0) }
                return
            }
            DualSenseHID.shared.setRumble(left: left, right: right)
        } else {
            events?.rumble(controller: 0, lowFreq: UInt16(left) * 257, highFreq: UInt16(right) * 257)
        }
    }

    /// Off in chiaki's intensity enum; as a nibble pair, 0xF0 | 0x0F.
    static let intensityOff: UInt8 = 0xFF

    /// The console's Vibration / Trigger Effect Intensity setting.
    private func applyIntensity(_ intensity: ChiakiDualSenseEffectIntensity, haptics: Bool) {
        let (hapticsLevel, triggerLevel) = Self.intensityNibbles(intensity)
        let (h, t, player) = lock.withLock { () -> (UInt8, UInt8, DualSenseHapticsOutput?) in
            if haptics { hapticsNibble = hapticsLevel } else { triggerNibble = triggerLevel }
            return (hapticsNibble, triggerNibble, audioHaptics)
        }
        if haptics { player?.setGain(intensity == Off ? 0 : 1) }
        if !haptics, intensity == Off {
            // Release whatever the triggers hold now.
            let off = [UInt8](repeating: 0, count: 10)
            lock.withLock { self.events }?.setAdaptiveTriggers(controller: 0, eventFlags: 0x0C, typeLeft: 0x05,
                                                               typeRight: 0x05, left: off, right: off)
        }
        DualSenseHID.shared.setIntensity(haptics: h, triggers: t)
        Diag.info("PS5: \(haptics ? "vibration" : "trigger effect") intensity \(intensity.rawValue)", Self.logCategory)
    }

    /// chiaki-ng's mapping to the pad's power-reduction nibbles:
    /// (haptics low nibble, triggers high nibble).
    static func intensityNibbles(_ intensity: ChiakiDualSenseEffectIntensity) -> (UInt8, UInt8) {
        switch intensity {
        case Strong: return (0x00, 0x00)
        // Trigger reduction is a 3-bit field (12.5% steps): PXPlay's 4 and 5.
        // chiaki-ng's 0x90 doesn't fit and read back as 1 (near full force).
        case Medium: return (0x02, 0x40)
        case Weak: return (0x03, 0x50)
        default: return (0x0F, 0xF0)   // Off
        }
    }

    // MARK: Controller feedback

    /// Same gates NativeBackend arms on connect: haptics actuator live, motion
    /// sampler uplinked to us, and motion reporting requested for pad 0 (the PS5
    /// reads motion whenever a game wants it; it never asks).
    private func armControllerFeedback() {
        ControllerHaptics.shared.streamActivated()
        ControllerMotion.shared.streamActivated(backend: self)
        DualSenseHID.shared.retain()
        lock.withLock { retainedHID = true }
        startAudioHaptics()
        // Chat starts muted, so the mute light is lit, as on the console.
        DualSenseHID.shared.setMicLED(lit: true)
        // Every pad, whatever its slot, and again whenever one reconnects
        // (USB <-> Bluetooth, sleep): the PS5 never asks.
        ControllerMotion.shared.enableForAllPads(rateHz: 200)
    }

    // MARK: Input uplink

    static var idlePad: ChiakiControllerState {
        var state = ChiakiControllerState()
        chiaki_controller_state_set_idle(&state)
        return state
    }

    /// Mutate one pad's state under the lock (log its first input of each kind).
    private func updatePad(_ num: UInt8, kind: String, _ body: (inout ChiakiControllerState) -> Void) {
        lock.withLock {
            var state = pads[num] ?? Self.idlePad
            body(&state)
            pads[num] = state
            if loggedInputFrom.insert("\(kind)#\(num)").inserted {
                Diag.notice("PS5: first \(kind) input from controller \(num)", Self.logCategory)
            }
        }
    }

    /// Merge every pad and send the result.
    private func pushPad() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard connected, let session else { return -2 }
        var merged = Self.idlePad
        for num in pads.keys.sorted() {
            var a = pads[num]!
            var b = merged
            chiaki_controller_state_or(&merged, &a, &b)
        }
        return chiaki_session_set_controller_state(session, &merged) == CHIAKI_ERR_SUCCESS ? 0 : -1
    }

    /// GameStream button flags → DualSense buttons. GameStream's A/B/X/Y are the
    /// Xbox positions (A bottom), which is how GameController reports a DualSense:
    /// cross = A, circle = B, square = X, triangle = Y.
    static func chiakiButtons(fromGameStream b: Int32) -> UInt32 {
        let map: [(Int32, UInt32)] = [
            (StreamProtocol.A_FLAG, CHIAKI_CONTROLLER_BUTTON_CROSS.rawValue),
            (StreamProtocol.B_FLAG, CHIAKI_CONTROLLER_BUTTON_MOON.rawValue),
            (StreamProtocol.X_FLAG, CHIAKI_CONTROLLER_BUTTON_BOX.rawValue),
            (StreamProtocol.Y_FLAG, CHIAKI_CONTROLLER_BUTTON_PYRAMID.rawValue),
            (StreamProtocol.UP_FLAG, CHIAKI_CONTROLLER_BUTTON_DPAD_UP.rawValue),
            (StreamProtocol.DOWN_FLAG, CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN.rawValue),
            (StreamProtocol.LEFT_FLAG, CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT.rawValue),
            (StreamProtocol.RIGHT_FLAG, CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT.rawValue),
            (StreamProtocol.LB_FLAG, CHIAKI_CONTROLLER_BUTTON_L1.rawValue),
            (StreamProtocol.RB_FLAG, CHIAKI_CONTROLLER_BUTTON_R1.rawValue),
            (StreamProtocol.LS_CLK_FLAG, CHIAKI_CONTROLLER_BUTTON_L3.rawValue),
            (StreamProtocol.RS_CLK_FLAG, CHIAKI_CONTROLLER_BUTTON_R3.rawValue),
            (StreamProtocol.PLAY_FLAG, CHIAKI_CONTROLLER_BUTTON_OPTIONS.rawValue),
            (StreamProtocol.BACK_FLAG, CHIAKI_CONTROLLER_BUTTON_SHARE.rawValue),
            (StreamProtocol.SPECIAL_FLAG, CHIAKI_CONTROLLER_BUTTON_PS.rawValue),
            (StreamProtocol.TOUCHPAD_FLAG, CHIAKI_CONTROLLER_BUTTON_TOUCHPAD.rawValue),
        ]
        var out: UInt32 = 0
        for (flag, button) in map where b & flag != 0 { out |= button }
        return out
    }

    /// GameStream sticks are Y-up (XInput); the PS5 wants Y-down.
    static func flipY(_ v: Int16) -> Int16 { v == Int16.min ? Int16.max : -v }

    func sendMultiController(num: Int16, mask: Int16, buttons: Int32, analog: GamepadAnalog) -> Int32 {
        // The DualSense Mute button (MISC on the wire) is the chat toggle, as on
        // the console; the PS5's controller state has no button for it.
        let pressed = buttons & StreamProtocol.MISC_FLAG != 0
        let padNum = UInt8(truncatingIfNeeded: num)
        let mic = lock.withLock { () -> PS5Microphone? in
            let wasHeld = muteHeld.contains(padNum)
            if pressed { muteHeld.insert(padNum) } else { muteHeld.remove(padNum) }
            return pressed && !wasHeld && connected ? microphone : nil
        }
        mic?.toggle()
        updatePad(padNum, kind: "button/stick") { pad in
            let analogTriggers = (analog.leftTrigger > 0 ? CHIAKI_CONTROLLER_ANALOG_BUTTON_L2.rawValue : 0)
                | (analog.rightTrigger > 0 ? CHIAKI_CONTROLLER_ANALOG_BUTTON_R2.rawValue : 0)
            pad.buttons = Self.chiakiButtons(fromGameStream: buttons) | analogTriggers
            pad.l2_state = analog.leftTrigger
            pad.r2_state = analog.rightTrigger
            pad.left_x = analog.leftStickX
            pad.left_y = Self.flipY(analog.leftStickY)
            pad.right_x = analog.rightStickX
            pad.right_y = Self.flipY(analog.rightStickY)
        }
        return pushPad()
    }

    func sendControllerArrival(num: UInt8, mask: UInt16, type: UInt8, supportedButtons: UInt32, caps: UInt16) -> Int32 { 0 }

    func sendControllerTouch(num: UInt8, eventType: UInt8, touchpadIndex: UInt8,
                             pointerId: UInt32, x: Float, y: Float, pressure: Float) -> Int32 {
        // DualSense touchpad space is 1920 x 1080 (chiaki-ng uses 1919 x 1079).
        let px = UInt16(max(0, min(1919, x * 1919)))
        let py = UInt16(max(0, min(1079, y * 1079)))
        updatePad(num, kind: "touch") { pad in
            var ids = touchIDs[num] ?? [:]
            switch Int32(eventType) {
            case StreamProtocol.LI_TOUCH_EVENT_DOWN:
                let id = chiaki_controller_state_start_touch(&pad, px, py)
                if id >= 0 { ids[pointerId] = id }
            case StreamProtocol.LI_TOUCH_EVENT_MOVE:
                if let id = ids[pointerId] { chiaki_controller_state_set_touch_pos(&pad, UInt8(id), px, py) }
            case StreamProtocol.LI_TOUCH_EVENT_UP, StreamProtocol.LI_TOUCH_EVENT_CANCEL:
                if let id = ids.removeValue(forKey: pointerId) { chiaki_controller_state_stop_touch(&pad, UInt8(id)) }
            case StreamProtocol.LI_TOUCH_EVENT_CANCEL_ALL:
                for id in ids.values { chiaki_controller_state_stop_touch(&pad, UInt8(id)) }
                ids.removeAll()
            default:
                break
            }
            touchIDs[num] = ids
        }
        return pushPad()
    }

    func sendControllerMotion(num: UInt8, motionType: UInt8, x: Float, y: Float, z: Float) -> Int32 {
        let now = UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1000)
        updatePad(num, kind: "motion") { pad in
            var m = motion[num] ?? PadMotion()
            if Int32(motionType) == StreamProtocol.LI_MOTION_TYPE_GYRO {
                // deg/s → rad/s
                let k = Float.pi / 180
                m.gyro(x * k, y * k, z * k, at: now)
            } else if Int32(motionType) == StreamProtocol.LI_MOTION_TYPE_ACCEL {
                // m/s² → g
                let g: Float = 9.80665
                m.accel(x / g, y / g, z / g, at: now)
            }
            chiaki_orientation_tracker_apply_to_controller_state(&m.tracker, &pad)
            motion[num] = m
        }
        return pushPad()
    }

    // MARK: Keyboard → controller
    //
    // The PS5 takes controller input only, so the keyboard drives a virtual
    // pad (merged with real ones), laid out like chiaki-ios:
    //   WASD left stick · IJKL right stick · arrows D-pad
    //   Return/Space Cross · Backspace Circle · F Square · R Triangle
    //   Q/E L1/R1 · Z/C L2/R2 · 1/2 L3/R3 · O Options · Y Create · Tab touchpad · H PS

    /// The virtual pad's slot in `pads` (real pads use GameStream's 0-15).
    static let keyboardPadNumber: UInt8 = 0xFE
    private var heldKeys: Set<UInt8> = []

    func sendKeyboard(keyCode: Int16, action: Int8, modifiers: Int8, flags: Int8) -> Int32 {
        let vk = UInt8(truncatingIfNeeded: UInt16(bitPattern: keyCode) & 0xFF)
        guard Self.keyboardKeys.contains(vk) else { return 0 }
        lock.withLock {
            if Int32(action) == StreamProtocol.KEY_ACTION_DOWN { heldKeys.insert(vk) } else { heldKeys.remove(vk) }
            pads[Self.keyboardPadNumber] = Self.keyboardPad(held: heldKeys)
            if loggedInputFrom.insert("keyboard").inserted {
                Diag.notice("PS5: keyboard driving the controller", Self.logCategory)
            }
        }
        return pushPad()
    }

    private enum VK {
        static let w: UInt8 = 0x57, a: UInt8 = 0x41, s: UInt8 = 0x53, d: UInt8 = 0x44
        static let i: UInt8 = 0x49, j: UInt8 = 0x4A, k: UInt8 = 0x4B, l: UInt8 = 0x4C
        static let left: UInt8 = 0x25, up: UInt8 = 0x26, right: UInt8 = 0x27, down: UInt8 = 0x28
        static let enter: UInt8 = 0x0D, space: UInt8 = 0x20, backspace: UInt8 = 0x08
        static let f: UInt8 = 0x46, r: UInt8 = 0x52, q: UInt8 = 0x51, e: UInt8 = 0x45
        static let z: UInt8 = 0x5A, c: UInt8 = 0x43, one: UInt8 = 0x31, two: UInt8 = 0x32
        static let o: UInt8 = 0x4F, y: UInt8 = 0x59, tab: UInt8 = 0x09, h: UInt8 = 0x48
    }

    private static let keyButtons: [UInt8: UInt32] = [
        VK.left: CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT.rawValue, VK.right: CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT.rawValue,
        VK.up: CHIAKI_CONTROLLER_BUTTON_DPAD_UP.rawValue, VK.down: CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN.rawValue,
        VK.enter: CHIAKI_CONTROLLER_BUTTON_CROSS.rawValue, VK.space: CHIAKI_CONTROLLER_BUTTON_CROSS.rawValue,
        VK.backspace: CHIAKI_CONTROLLER_BUTTON_MOON.rawValue, VK.f: CHIAKI_CONTROLLER_BUTTON_BOX.rawValue,
        VK.r: CHIAKI_CONTROLLER_BUTTON_PYRAMID.rawValue, VK.q: CHIAKI_CONTROLLER_BUTTON_L1.rawValue,
        VK.e: CHIAKI_CONTROLLER_BUTTON_R1.rawValue, VK.one: CHIAKI_CONTROLLER_BUTTON_L3.rawValue,
        VK.two: CHIAKI_CONTROLLER_BUTTON_R3.rawValue, VK.o: CHIAKI_CONTROLLER_BUTTON_OPTIONS.rawValue,
        VK.y: CHIAKI_CONTROLLER_BUTTON_SHARE.rawValue, VK.tab: CHIAKI_CONTROLLER_BUTTON_TOUCHPAD.rawValue,
        VK.h: CHIAKI_CONTROLLER_BUTTON_PS.rawValue,
    ]
    static let keyboardKeys: Set<UInt8> = Set(keyButtons.keys).union(
        [VK.w, VK.a, VK.s, VK.d, VK.i, VK.j, VK.k, VK.l, VK.z, VK.c])

    /// Debug: `--debug-ps5-keys=right@3,cross@5,r2@8:2,rumble@10:3` presses
    /// virtual-pad buttons (name@seconds-after-connect[:hold seconds]) so a
    /// stream can be driven with nobody at the Mac; `rumble` fakes the
    /// console's rumble event.
    private func runDebugKeys() {
        let prefix = "--debug-ps5-keys="
        guard let spec = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) })?
            .dropFirst(prefix.count) else { return }
        let names: [String: UInt8] = [
            "left": VK.left, "right": VK.right, "up": VK.up, "down": VK.down, "cross": VK.enter,
            "circle": VK.backspace, "square": VK.f, "triangle": VK.r, "l1": VK.q, "r1": VK.e,
            "l2": VK.z, "r2": VK.c, "options": VK.o, "ps": VK.h, "touchpad": VK.tab,
            "lup": VK.w, "ldown": VK.s, "lleft": VK.a, "lright": VK.d,
        ]
        for step in spec.split(separator: ",") {
            let parts = step.split(separator: "@")
            guard parts.count == 2 else { continue }
            let timing = parts[1].split(separator: ":").compactMap { Double($0) }
            guard let at = timing.first else { continue }
            let hold = timing.count > 1 ? timing[1] : 0.12
            if parts[0] == "haptics" {         // a 90 Hz tone, as if the console sent it
                DispatchQueue.global().asyncAfter(deadline: .now() + at) { [weak self] in
                    self?.playDebugHaptics(seconds: hold)
                }
                continue
            }
            if parts[0] == "mic" {             // the Mute button: chat live <-> muted
                DispatchQueue.global().asyncAfter(deadline: .now() + at) { [weak self] in
                    guard let self else { return }
                    self.lock.withLock { self.microphone }?.toggle()
                }
                continue
            }
            if parts[0] == "rumble" {          // as if the console sent half-strength rumble
                DispatchQueue.global().asyncAfter(deadline: .now() + at) { [weak self] in
                    self?.handleRumble(left: 128, right: 128)
                    DispatchQueue.global().asyncAfter(deadline: .now() + hold) { [weak self] in
                        self?.handleRumble(left: 0, right: 0)
                    }
                }
                continue
            }
            guard let vk = names[String(parts[0])] else { continue }
            let key = Int16(vk)
            DispatchQueue.global().asyncAfter(deadline: .now() + at) { [weak self] in
                _ = self?.sendKeyboard(keyCode: key, action: Int8(StreamProtocol.KEY_ACTION_DOWN), modifiers: 0, flags: 0)
                DispatchQueue.global().asyncAfter(deadline: .now() + hold) { [weak self] in
                    _ = self?.sendKeyboard(keyCode: key, action: Int8(StreamProtocol.KEY_ACTION_UP), modifiers: 0, flags: 0)
                }
            }
        }
        Diag.notice("PS5: debug keys scheduled: \(spec)", Self.logCategory)
    }

    /// Held keys → one pad state. Sticks are full deflection, Y-down (the
    /// console's convention); opposite keys cancel.
    static func keyboardPad(held: Set<UInt8>) -> ChiakiControllerState {
        var pad = idlePad
        for key in held { pad.buttons |= keyButtons[key] ?? 0 }
        func axis(_ neg: UInt8, _ pos: UInt8) -> Int16 {
            (held.contains(pos) ? Int16.max : 0) - (held.contains(neg) ? Int16.max : 0)
        }
        pad.left_x = axis(VK.a, VK.d)
        pad.left_y = axis(VK.w, VK.s)
        pad.right_x = axis(VK.j, VK.l)
        pad.right_y = axis(VK.i, VK.k)
        if held.contains(VK.z) {
            pad.l2_state = 255
            pad.buttons |= CHIAKI_CONTROLLER_ANALOG_BUTTON_L2.rawValue
        }
        if held.contains(VK.c) {
            pad.r2_state = 255
            pad.buttons |= CHIAKI_CONTROLLER_ANALOG_BUTTON_R2.rawValue
        }
        return pad
    }

    // The mouse has no PS5 counterpart.
    func sendMouseMove(dx: Int16, dy: Int16) -> Int32 { 0 }
    func sendMousePosition(x: Int16, y: Int16, refW: Int16, refH: Int16) -> Int32 { 0 }
    func sendMouseButton(action: Int8, button: Int32) -> Int32 { 0 }
    func sendScroll(_ amount: Int16) -> Int32 { 0 }
    func sendHScroll(_ amount: Int16) -> Int32 { 0 }
}

/// One pad's motion as the PS5 wants it: rates, gravity, and an attitude
/// integrated from them (chiaki-ng's ChiakiOrientationTracker, fed the way
/// its controllermanager.cpp does). Gyro in rad/s, accel in g, SDL axes.
struct PadMotion {
    var tracker = ChiakiOrientationTracker()
    /// Subtracted from the accelerometer after a re-centre.
    var zero = ChiakiAccelNewZero()
    /// The last raw accelerometer reading (before `zero`).
    var raw: (x: Float, y: Float, z: Float) = (0, 1, 0)

    init() {
        chiaki_orientation_tracker_init(&tracker)
        chiaki_accel_new_zero_set_inactive(&zero, false)
    }

    mutating func gyro(_ x: Float, _ y: Float, _ z: Float, at us: UInt32) {
        chiaki_orientation_tracker_update(&tracker, x, y, z,
                                          tracker.accel_x, tracker.accel_y, tracker.accel_z, &zero, true, us)
    }

    mutating func accel(_ x: Float, _ y: Float, _ z: Float, at us: UInt32) {
        raw = (x, y, z)
        chiaki_orientation_tracker_update(&tracker, tracker.gyro_x, tracker.gyro_y, tracker.gyro_z,
                                          x, y, z, &zero, false, us)
    }

    /// The pad's current pose becomes level (CHIAKI_EVENT_MOTION_RESET).
    mutating func recenter() {
        let g = (tracker.gyro_x, tracker.gyro_y, tracker.gyro_z)
        let us = tracker.timestamp
        chiaki_accel_new_zero_set_active(&zero, raw.x, raw.y, raw.z, false)
        chiaki_orientation_tracker_init(&tracker)
        chiaki_orientation_tracker_update(&tracker, g.0, g.1, g.2, raw.x, raw.y, raw.z, &zero, false, us)
    }
}

/// Debug: the console's haptics frames written as received:
/// [u64 arrival ns][u16 byte count][Int16 L/R PCM] per frame, little endian.
final class HapticsDump {
    private let handle: FileHandle

    static func openIfEnabled() -> HapticsDump? {
        guard UserDefaults.standard.bool(forKey: "PS5.debugDumpHaptics") else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Shimmer")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("haptics-\(stamp).bin")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        Diag.notice("PS5: dumping haptics frames to \(url.lastPathComponent)", "PlayStation")
        return HapticsDump(handle: handle)
    }

    private init(handle: FileHandle) { self.handle = handle }
    deinit { try? handle.close() }

    func write(arrival: UInt64, pcm: UnsafeRawBufferPointer) {
        var header = Data(count: 10)
        header.withUnsafeMutableBytes {
            $0.storeBytes(of: arrival.littleEndian, toByteOffset: 0, as: UInt64.self)
            $0.storeBytes(of: UInt16(pcm.count).littleEndian, toByteOffset: 8, as: UInt16.self)
        }
        header.append(contentsOf: pcm)
        try? handle.write(contentsOf: header)
    }
}
