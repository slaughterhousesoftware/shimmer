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
    private let connectSignal = DispatchSemaphore(value: 0)

    // Controller state per GameStream controller number. Remote Play takes one
    // controller, so every connected pad is merged into it (buttons OR'd,
    // sticks by largest deflection, motion from the first pad that has any).
    private var pads: [UInt8: ChiakiControllerState] = [:]
    private var touchIDs: [UInt8: [UInt32: Int8]] = [:]
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

    /// libchiaki hands audio and video over on ONE receive thread. Decoding
    /// inline would hold audio behind every slow video submit (measured: audio
    /// under-runs clustered on PiP enter/return), so each medium gets its own
    /// serial queue, as the Sunshine engine has its own receive threads.
    private let videoQueue = DispatchQueue(label: "Shimmer.PlayStation.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "Shimmer.PlayStation.audio", qos: .userInteractive)

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
        info.video_profile_auto_downgrade = true
        info.enable_keyboard = false
        info.enable_dualsense = false
        info.enable_idr_on_fec_failure = true
        info.packet_loss_max = 0.05

        let session = UnsafeMutablePointer<ChiakiSession>.allocate(capacity: 1)
        session.initialize(to: ChiakiSession())
        let err = chiaki_session_init(session, &info, chiakiLog)
        guard err == CHIAKI_ERR_SUCCESS else {
            session.deallocate()
            events.stageFailed("PS5 session", code: Int32(err.rawValue))
            throw StreamError.sessionFailed(Int32(err.rawValue))
        }

        // The decoder is set up before the first frame can arrive.
        let setup = videoSink.setup(videoFormat: options.videoFormat, width: options.width,
                                    height: options.height, redrawRate: Int32(options.fps))
        guard setup == 0 else {
            chiaki_session_fini(session)
            session.deallocate()
            events.stageFailed("PS5 session", code: setup)
            throw StreamError.sessionFailed(setup)
        }
        videoSink.start()

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

        let startErr = chiaki_session_start(session)
        guard startErr == CHIAKI_ERR_SUCCESS else {
            events.stageFailed("PS5 session", code: Int32(startErr.rawValue))
            stopConnection()
            throw StreamError.sessionFailed(Int32(startErr.rawValue))
        }

        // Block (we run on StreamSession's connect task) until the console
        // says CONNECTED, quits, or 20 s pass.
        let waited = connectSignal.wait(timeout: .now() + 20)
        let (isConnected, message) = lock.withLock { (connected, quitMessage) }
        guard waited == .success, isConnected else {
            let reason = message ?? "the PS5 did not answer within 20 s"
            Diag.error("PS5: connect failed - \(reason)", Self.logCategory)
            events.stageFailed("PS5 session", code: -1)
            stopConnection()
            throw StreamError.hostUnreachable(reason)
        }
        events.stageComplete("PS5 session")
        armControllerFeedback()
        events.connectionStarted()
    }

    func stopConnection() {
        let (session, retained, video, audio) = lock.withLock { () -> (UnsafeMutablePointer<ChiakiSession>?, Unmanaged<PlayStationBackend>?, VideoSink?, NativeAudioSink?) in
            let s = self.session
            let r = self.retainedSelf
            self.session = nil
            self.retainedSelf = nil
            self.stopped = true
            return (s, r, self.videoSink, self.audioSink)
        }
        connectSignal.signal()
        if let session {
            Diag.info("PS5: stopping session", Self.logCategory)
            chiaki_session_stop(session)
            chiaki_session_join(session)
            chiaki_session_fini(session)
            session.deinitialize(count: 1)
            session.deallocate()
        }
        // Let queued frames finish before the sinks are torn down.
        videoQueue.sync {}
        audioQueue.sync {}
        ControllerHaptics.shared.stopAll(reason: "stream teardown")
        ControllerMotion.shared.stopAll(reason: "stream teardown")
        video?.stop()
        video?.cleanup()
        audio?.cleanup()
        retained?.release()
    }

    func interruptConnection() {
        let session = lock.withLock { self.session }
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

    func requestIdrFrame() {
        if let session = lock.withLock({ self.session }) { _ = chiaki_session_request_idr(session) }
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
                return (connected, stopped, self.events)
            }
            Diag.notice("PS5: session ended - \(message)", Self.logCategory)
            connectSignal.signal()
            // Only a live session that the console (not we) ended is a terminate.
            if wasConnected && !wasStopped {
                events?.connectionTerminated(code: isError ? Self.terminatedWithError : Self.terminatedCleanly)
            }
        case CHIAKI_EVENT_RUMBLE:
            let events = lock.withLock { self.events }
            events?.rumble(controller: 0, lowFreq: UInt16(event.rumble.left) * 257,
                           highFreq: UInt16(event.rumble.right) * 257)
        case CHIAKI_EVENT_LED_COLOR:
            let events = lock.withLock { self.events }
            let led = event.led_state
            events?.setControllerLED(controller: 0, r: led.0, g: led.1, b: led.2)
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
        let unit = DecodeUnit(
            frameNumber: frameNumber,
            frameType: isIDR ? VideoDepacketizer.FRAME_TYPE_IDR : 0,
            fullLength: Int32(data.count),
            frameHostProcessingLatency: 0,
            receiveTimeUs: nowUs,
            enqueueTimeUs: nowUs,
            presentationTimeUs: nowUs,
            // 90 kHz capture-style clock from arrival time; never 0.
            rtpTimestamp: UInt32(truncatingIfNeeded: nowUs * 9 / 100) | 1,
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

    // MARK: Controller feedback

    /// Same gates NativeBackend arms on connect: haptics actuator live, motion
    /// sampler uplinked to us, and motion reporting requested for pad 0 (the PS5
    /// reads motion whenever a game wants it; it never asks).
    private func armControllerFeedback() {
        ControllerHaptics.shared.streamActivated()
        ControllerMotion.shared.streamActivated(backend: self)
        let events = lock.withLock { self.events }
        events?.setMotionEventState(controller: 0, motionType: UInt8(StreamProtocol.LI_MOTION_TYPE_ACCEL), reportRateHz: 100)
        events?.setMotionEventState(controller: 0, motionType: UInt8(StreamProtocol.LI_MOTION_TYPE_GYRO), reportRateHz: 100)
    }

    // MARK: Input uplink

    private static var idlePad: ChiakiControllerState {
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
        updatePad(UInt8(truncatingIfNeeded: num), kind: "button/stick") { pad in
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
        updatePad(num, kind: "motion") { pad in
            if Int32(motionType) == StreamProtocol.LI_MOTION_TYPE_GYRO {
                // deg/s → rad/s
                let k = Float.pi / 180
                pad.gyro_x = x * k; pad.gyro_y = y * k; pad.gyro_z = z * k
            } else if Int32(motionType) == StreamProtocol.LI_MOTION_TYPE_ACCEL {
                // m/s² → g
                let g: Float = 9.80665
                pad.accel_x = x / g; pad.accel_y = y / g; pad.accel_z = z / g
            }
        }
        return pushPad()
    }

    // The PS5 takes controller input only.
    func sendKeyboard(keyCode: Int16, action: Int8, modifiers: Int8, flags: Int8) -> Int32 { 0 }
    func sendMouseMove(dx: Int16, dy: Int16) -> Int32 { 0 }
    func sendMousePosition(x: Int16, y: Int16, refW: Int16, refH: Int16) -> Int32 { 0 }
    func sendMouseButton(action: Int8, button: Int32) -> Int32 { 0 }
    func sendScroll(_ amount: Int16) -> Int32 { 0 }
    func sendHScroll(_ amount: Int16) -> Int32 { 0 }
}
