# Architecture

Shimmer is a SwiftUI launcher that lives in the menu bar plus two streaming
engines, in one process:

- **Sunshine / GameStream PCs** - a pure-Swift engine under
  `Glimmer/Stream/Native/` (ported from `moonlight-common-c`, GPLv3; see
  [CREDITS.md](../CREDITS.md)). No linked C streaming library on this path.
- **PS5 Remote Play** - `PlayStationBackend` (`Glimmer/PlayStation/`) over
  chiaki-ng's `libchiaki`, a C library built as a static archive from the
  `third_party/chiaki-ng` submodule with Shimmer's patches
  (`third_party/chiaki-ng-patches/`, applied by `scripts/build-libchiaki.sh`).

Both sit behind one protocol, `StreamingBackend`, and feed the same decoder,
pacer, audio path, window and input forwarder. The other C that crosses the
bridging header is Opus (audio decode) and OpenSSL (identity / pairing / network
crypto), plus a few inline shims in `CHelpers.h`.

The source tree, targets and log subsystem still carry the upstream project's
name, Glimmer; the app is Shimmer.

## Overview

The user picks a machine - in the window, or from the menu bar's menu - clicks
Stream, and a stream window opens (or the stream opens straight into Picture in
Picture). Decoded H.264 / HEVC / AV1 (8- or 10-bit, SDR or
HDR10) is paced by a display-link-driven `FramePacer` onto an
`AVSampleBufferDisplayLayer` for the OS to paint. Mouse / keyboard / gamepad
input is forwarded to the host through the `StreamingBackend` input methods
(coalesced by an `InputBatcher` onto the reliable control channel). When the
user hits the quit hotkey, the backend is told to disconnect and the window
comes down.

## Process model

Single process, single in-flight stream. `StreamSession.start()`
(`StreamSession+Start.swift`) refuses to start a second session while one is
running (`isStreaming` guard).

Top-level pieces:

| Layer                 | Type                                                       | Lives where                                             |
| --------------------- | ---------------------------------------------------------- | ------------------------------------------------------- |
| SwiftUI views         | views + observable state                                   | `Glimmer/ContentView.swift`, `SettingsView.swift`       |
| `AppModel`            | `@MainActor` `@Observable`                                 | `Glimmer/AppModel.swift` (+ extensions)                 |
| `StreamSession`       | `actor`                                                    | `Glimmer/Stream/StreamSession.swift` (+ extensions)     |
| `StreamingBackend`    | protocol (the engine boundary)                             | `Glimmer/Stream/StreamingBackend.swift`                 |
| `NativeBackend`       | `final class`, the Sunshine backend                        | `Glimmer/Stream/NativeBackend.swift` + `Stream/Native/` |
| `PlayStationBackend`  | `final class`, the PS5 backend (libchiaki)                 | `Glimmer/PlayStation/PlayStationBackend.swift`          |
| `StreamBridgeContext` | `final class`, `@unchecked Sendable`                       | `Glimmer/Stream/StreamBridgeContext.swift`              |
| `NetworkClient`       | `actor` over `ControlTransport` (hand-rolled OpenSSL mTLS) | `Glimmer/Stream/Network.swift`                          |
| `PairingClient`       | `actor`                                                    | `Glimmer/Stream/Pairing.swift`                          |
| `IdentityManager`     | `actor` (singleton)                                        | `Glimmer/Stream/Identity.swift`                         |
| `VideoDecoder`        | `@MainActor final class`                                   | `Glimmer/Stream/VideoDecoder.swift` (+ extensions)      |
| `FramePacer`          | `final class`, `@unchecked Sendable`                       | `Glimmer/Stream/FramePacer.swift` (+ extensions)        |
| `AudioDecoder`        | `final class`, `@unchecked Sendable`                       | `Glimmer/Stream/AudioDecoder.swift`                     |
| `InputForwarder`      | `@MainActor final class`                                   | `Glimmer/Stream/InputForwarder.swift`                   |
| `ControllerForwarder` | `@MainActor` extension on InputForwarder                   | `Glimmer/Stream/ControllerForwarder.swift`              |
| `StreamWindow`        | `@MainActor final class`                                   | `Glimmer/Stream/StreamWindow.swift`                     |
| `StatsCollector`      | `final class`, `@unchecked Sendable`                       | `Glimmer/Stream/StatsCollector.swift`                   |
| Telemetry (opt-in)    | exporter + counters                                        | `Glimmer/Stream/TelemetryExporter.swift` (+ extensions) |

> The control/HTTP path runs over `ControlTransport` (`ControlTransport.swift`):
> a hand-rolled OpenSSL + POSIX-socket mutual-TLS client, deliberately **not**
> `URLSession` - this keeps the (sleep-locking) keychain out of the path.

## The `StreamingBackend` boundary

`Glimmer/Stream/StreamingBackend.swift` is **the** streaming-engine abstraction:
one protocol for lifecycle / telemetry / input uplink, plus sink protocols for
the inbound direction (`VideoSink`, `AudioSink`, `ConnectionEvents`), plus
Glimmer-owned value types (`BackendServerInfo`, `BackendStreamConfig`,
`DecodeUnit`, `DecodeBuffer`, `OpusConfig`, `HdrMetadata`, `GamepadAnalog`) so
nothing outside the engine sees wire-level types. `NativeBackend` (Sunshine) and
`PlayStationBackend` (PS5) are the two conformers; `AppModel.makeStreamingBackend`
picks by host.

The method set deliberately mirrors the GameStream protocol surface - the
outbound input methods map 1:1 to the `LiSend*` family the protocol defines, and
doc comments keep the `Li*` names as spec citations - so the protocol itself
documents the wire contract the engine satisfies.

Protocol constants live in a Swift mirror (`StreamProtocolConstants.swift`,
`enum StreamProtocol`); nothing imports a `Limelight.h`.

## The native engine (`Glimmer/Stream/Native/`)

`NativeBackend.startConnection` drives the whole bring-up:

```
name resolution → RTSP/SDP handshake over TCP (OPTIONS, DESCRIBE,
SETUP audio/video/control, ANNOUNCE, PLAY) → ENet-subset reliable-UDP
CONTROL channel CONNECT / VERIFY_CONNECT / ACK → START_A → START_B →
connected → stream pings + RTP receive → FEC → depacketize → sinks
```

Components:

- **`RtspClient`** (+`+Handshake`) - the RTSP/SDP rounds, including Sunshine's
  encrypted-RTSP variant. `SdpCodec` builds/parses the SDP payloads.
- **`EnetControlChannel`** (+`+Handshake`, `+ControlLoop`, `+Inbound`, `+Send`)
  - a focused, single-peer, client-only ENet subset over UDP: the CONNECT
    handshake, reliable sends with ACK tracking, and the inbound control
    dispatch (rumble, HDR mode, motion enable, lightbar, termination).
    `EnetWire.swift` owns the byte layout (enet wire format; see CREDITS.md).
- **`StreamCrypto`** - control-V2 AES-GCM encryption for control messages and
  the media-stream decrypt paths.
- **Video receive** - `VideoRtpReceiver` (socket + ping loop) → `RtpVideoQueue`
  (+`+AddPacket`, `+Reconstruct`, `+ReceiveQuality`, `+ReorderStats`) which
  reorders, FEC-recovers, and assembles packets → `VideoDepacketizer` which
  emits `DecodeUnit`s to the `VideoSink` (the `VideoDecoder`).
  `ReedSolomon.swift` is the GF(256) erasure decoder (see CREDITS.md).
  `FecHeadroomController` adaptively deepens receive headroom under sustained
  loss with a bounded, recovering control loop.
- **Audio receive** - `RtpAudioReceiver` (+`+Socket`, `+Decrypt`, `+Ping`,
  `+StartupGate`, `+Events`, `+Telemetry`) → `RtpAudioQueue` (+`+Fec`) /
  `AudioFecDecoder` → Opus decode in `AudioDecoder` (AVAudioEngine playout with
  an adaptive cushion).
- **`StreamPathMTU`** - a connect-time egress path-MTU probe. It resolves
  `StreamConfig.remoteness == .auto` from the real route, so the SDP packet-size
  clamp (1392 down to 1024 on a tunnelled path) fires on the paths that need it.
- **Input uplink** - `InputBatcher` + `InputEncoder`: queue + merge + ~1ms flush
  coalescing high-rate mouse / controller deltas so the reliable channel carries
  ~1 packet per change per tick instead of 150-250/s.
- **`UdpPinger`** - stream-keepalive ping plumbing and the single steady-cadence
  dial both live receive loops ride.

Inbound callbacks fire on the engine's receive threads and are routed through
`StreamBridgeContext` (below). Stage events (`stageStarting` / `stageComplete` /
`stageFailed`) yield through the bridge's event continuation so the connection
UI lights up live.

## Stream session lifecycle

A `StreamSession` is one-shot: one per stream, built by
`AppModel.launchSession`. `start(server:config:appID:...)` returns an
`AsyncStream<StreamEvent>` that drives the UI. The phases (Sunshine; a PS5
skips 1-3):

0. **PS5 only, before the session exists** - `AppModel.readyPlayStation`: probe
   the console, look for it at a new address if it doesn't answer, and wake it
   from rest mode (wake packet re-sent every 6 s, 40 s in all). This is part of
   the stream attempt: the row reads "Waking…", Cancel / End Stream / a switch
   cancel it (`streamPreflightTask`), and a console that stays in rest mode
   fails as "didn't wake" without going on to connect.
1. **Verify pairing** - refused outright without a pinned certificate
   (`hasPinnedCertificate`); then `NetworkClient.fetchServerInfo()` over the
   pinned TLS channel. `pairStatus != .paired` throws.
2. **Launch, resume, or cancel + launch** - `launchPlan(hintCurrentGame:appID:)`:
   idle → `/launch`; our own app already running → `/resume` (Sunshine takes
   the new mode from the request); another app → `/cancel`, poll until idle,
   `/launch` (the takeover the launcher confirmed). Bounded by
   `launchWithDeadline`. The `LaunchResponse` records `resumed`.
3. **Build `BackendStreamConfig`** - width / height / fps / bitrate / codec
   bitmask / colorspace / colorRange / encryptionFlags, plus the remote-input
   AES key + IV from the launch response.
4. **Build window + decoder + input on the main actor** - attached to the
   window's `AVSampleBufferDisplayLayer` before the connection starts.
5. **Build `StreamBridgeContext`** and **the event stream**, before the
   connect: the backend fires stage events while it connects.
6. **`backend.startConnectionAsync`** - awaited, never blocking the actor;
   throws on failure.
7. **Install timers** - stats overlay, the 1 Hz frame watchdog, the
   present-path watchdog, the present-metric sampler, the sleep/wake observers.

### Stopping while starting

`start()` owns everything it builds until it returns. A `stop()` that arrives
meanwhile does not tear down between `start()`'s awaits: it latches
`stopRequested`, interrupts the connect, and waits (`stop(cause:)`); `start()`
reads the latch after each await, tears down what it has built
(`performStop`), and throws `.cancelled` - or a failed-connect error if the PC,
not the user, caused the stop (`errorForStopDuringStart`). Before this, a stop
that landed between two awaits was followed by a completed connect: a live
stream every later `stop()` refused at its guard.

AppModel also cancels the task running `start()` (`streamStartTask`), which
aborts an in-flight control request instead of waiting out its socket timeout.

### Failures

Errors keep their cause up to the launcher. `StreamError` carries
`.connectFailed(ConnectFailure)` for a Sunshine connect that failed after the
PC had answered (which leg: stream port, control channel, a refused RTSP step,
a PC that went quiet), `.playStation(PlayStationFailure)` for a PS5 refusal (in
use, registration rejected, wrong account, passcode, didn't wake, on but not
answering), and `.cancelled`. `StreamFailureCopy` is the one table that turns
any of them into the sentence shown - on the machine's page under its Stream
row, and in the menu bar's menu. A cancelled start shows nothing.

A connect that fails after `/launch` sends `/cancel` only to undo an app this
attempt itself launched (`shouldCancelHostSession`): never after `/resume`, and
never from a reconnect attempt - `/cancel` quits the game.

### Mid-stream

- **Host terminate / dead peer** - `handleHostTerminate`: a recoverable code,
  our own dead-peer cutoff (10 s without an ACK), or an ENet DISCONNECT on a
  stream that had been live starts a reconnect episode in place
  (`StreamSession+Reconnect.swift`): frozen frame, "Reconnecting…" banner,
  bounded attempts. A PS5 session has nothing to relaunch and ends.
- **Frame watchdog** (10 s without a decoded frame) - `watchdogTimeoutAction`:
  control link still ACKed → hold (the PC paused video); control link quiet
  too → reconnect; never a first frame, or a PS5 → end.
- **Present watchdog** (`StreamSession+Watchdog.swift`, `+PresentTrip.swift`) -
  recovers a present path that stops while decode is healthy. Suppressed while
  nothing can be seen. A silent display link only counts when frames are
  queued behind it (`linkDeadTripped`).
- **Sleep / wake** - `StreamSession+Wake.swift` probes the link on wake and
  reconnects if it is stale.

### Teardown

`performStop` is the one teardown; `stop(cause:)` is its entry point from
outside `start()`. Re-entrant by design (`isStreaming` + `stopInProgress`).
Order is load-bearing:

1. Invalidate the main-run-loop timers and hide the overlay. Release every key,
   button and modifier the host holds and rest the pads
   (`InputForwarder.releaseEverythingBeforeDisconnect`) while the connection
   can still carry it.
2. `backend.stopConnection()` - the input batcher sends what it holds, the ENet
   channel sends DISCONNECT so the host ends the session at once, receive /
   control threads stop.
3. `/cancel` only when the stream is meant to quit the app ("Quit the game
   when the stream ends"); otherwise the app stays up on the PC for `/resume`.
4. MainActor teardowns: `input.detach()`, `videoDecoder.teardown()`,
   `window.close()`.
5. `audioDecoder.shutdown()`.
6. Clear `StreamBridgeContext.current`, release the bridge's retain, `finish()`
   the event stream (which is how AppModel learns the stream is over).
7. Release the power assertions.

AppModel has one cleanup site too (`cleanupAfterStream`), run when `start()`
throws or the event loop drains, and it ignores sessions that are no longer the
current one (`currentStreamToken`).

## PlayStation (PS5 Remote Play)

`PlayStationBackend` wraps one `ChiakiSession`. Registration
(`PlayStationRegistration`) stores the console's keys in
`~/Library/Application Support/Shimmer/PlayStation/consoles.json` (mode 0600;
an unreadable file is moved aside, never saved over). Discovery and wake are in
`PlayStationDiscovery`.

- **Connect** - up to six attempts: the console holds a just-ended session for
  a few seconds ("in use"), and a just-woken console refuses briefly. A session
  that fails on Takion 20 retries on 12. QUIT reasons map to
  `PlayStationFailure` (`failure(for:)`); patch 0012 adds the two refusal
  reasons libchiaki folded into "unknown".
- **Threads** - libchiaki calls back on its own threads; `lock` guards the
  backend's state. Calls that send on the ctrl channel (join, leave, go to
  rest, stop) go through `withSession`, outside `lock`: the ctrl thread
  delivers events while holding its own mutex, and those handlers take `lock`.
  A use count keeps teardown from freeing the session under such a call.
- **Presentation** - by default frames go straight to the layer
  (`VideoDecoder.presentsDirect`); "Smooth" uses the frame pacer.
- **Controllers** - every pad merges into player 1 unless the console seats it
  as player 2-4 (`PS5.extraPlayers`). Player 1's pad leads the merge. DualSense
  haptics arrive as audio and play through `DualSenseAudioHaptics` (USB) or the
  Bluetooth path; adaptive triggers and the light bar go through `DualSenseHID`.
- **Microphone** - `PS5Microphone`.

## Video pipeline

Owned by `VideoDecoder` (`Glimmer/Stream/VideoDecoder.swift`), with HDR
specifics in `+HDR.swift` and bitstream parsing in `+Bitstream.swift`.

**Packet ingest.** The native engine's depacketizer invokes
`submitDecodeUnit(_:)` on its receive thread with an Annex-B elementary-stream
`DecodeUnit`. We assemble it into a single `Data` buffer, watch for SPS/PPS/VPS
NALs (or the AV1 sequence header OBU), rebuild the `CMVideoFormatDescription` on
IDR, and submit the sample to `VTDecompressionSessionDecodeFrame`.

**VT decode.** `VTDecompressionSession` is built with hardware acceleration
required (`VTIsHardwareDecodeSupported` is checked per codec at setup).
`kVTDecompressionPropertyKey_RealTime` is set so VT prefers latency over peak
quality. The output callback fires on our `decodeQueue` (a user-interactive
`DispatchQueue`) with a `CVPixelBuffer`.

**Pacing + enqueue.** The VT output callback wraps the pixel buffer + format
description in a `CMSampleBuffer` and submits it to the `FramePacer` - a
display-clock pacer (a two-queue model on `AVSampleBufferDisplayLayer` +
`CADisplayLink`). Frames land in a bounded, hostPTS-ordered jitter/reorder FIFO;
a `CADisplayLink` bound to the stream window's screen releases at most one due
frame per vsync to `displayLayer.sampleBufferRenderer.enqueue(_:)`
(`AVSampleBufferVideoRenderer`, the macOS 15+ replacement for the deprecated
`enqueueSampleBuffer`). The release path runs on a dedicated serial queue, never
the main actor. The pacer's queue depth is adaptive: it rests at 1 frame on a
clean link and grows only under measured (RFC-3550) reorder jitter, decaying
back when the link is clean - see the rationale comments in `FramePacer.swift`
and `FramePacer+Constants.swift`. There is no Metal shader - the OS owns
color/EDR handling end-to-end.

The Metal-shader rewrite this used to be is documented in the top-of-file
comment in `VideoDecoder.swift`. Short version: with a custom MSL fragment
shader doing the YUV→RGB + PQ EOTF, HDR was visibly wrong (washed highlights,
milky blacks) on real HDR displays. Apple's Metal docs explicitly say "don't
tone-map in your shader, the layer applies tone mapping based on the current EDR
headroom." The OS owns the pipeline end-to-end, and HDR works.

**HDR pipeline.** Active when all three preconditions hold:

1. Host signalled HDR via the control channel's HDR-mode message.
2. Stream is 10-bit (`streamVideoFormat & VIDEO_FORMAT_MASK_10BIT != 0`).
3. The bitstream's VUI / AV1 sequence-header `color_config` declares PQ (SMPTE
   ST 2084) - or, for untagged Sunshine bitstreams, we infer PQ from the
   10-bit + HDR-mode pair.

When active, `VideoDecoder+HDR.configureLayerColorspace` sets:

- `layer.preferredDynamicRange = .high` (macOS 26+ API; replaces the older
  `wantsExtendedDynamicRangeContent` Bool).
- `layer.setValue(CGColorSpace(name: .itur_2100_PQ), forKey: "colorspace")` -
  via KVC because the Swift overlay elides the property on the
  `AVSampleBufferDisplayLayer` subclass.

Per-frame attachments on the `CVPixelBuffer`:

- `kCVImageBufferColorPrimariesKey` = `ITU_R_2020`.
- `kCVImageBufferTransferFunctionKey` = `SMPTE_ST_2084_PQ`.
- `kCVImageBufferYCbCrMatrixKey` = `ITU_R_2020`.

HDR10 static metadata comes from the host (the native engine surfaces it via
`StreamingBackend.hdrMetadata()`, filled from the SDP mastering metadata) and is
attached as `CMFormatDescription` extensions in the exact HDR10 wire layout
(MDCV: GBR ordering, big-endian; CLL: 4 bytes big-endian). See
`VideoDecoder+HDR.refreshHDRMetadataFromHost()` for the byte-by-byte build. The
cached HDR format description is rebuilt whenever metadata changes (host
re-signals HDR with new values, e.g. a game changes EOTF or the host display is
hot-swapped).

When HDR drops back to SDR, `preferredDynamicRange` returns to `.standard`, the
layer's `colorspace` is cleared, and the next-frame fallback attaches BT.709
primaries.

**Backpressure + recovery.** `AVSampleBufferVideoRenderer.status == .failed`
latches after a bad sample (mid-stream SPS change, dirty AV1 OBU). We watch for
that on each enqueue: on failure, `renderer.flush()` and
`backend.requestIdrFrame()`. `RendererFailed` OSSignpost event fires so it shows
in Instruments. `isReadyForMoreMediaData` is also honored - when the renderer's
internal queue fills, frames drop (counted) rather than queueing unbounded
latency. A hidden/occluded stream window suppresses presentation and, after a
sustained window, gates VideoToolbox decode entirely (the host cannot pause;
audio/network/FEC keep running); resume reuses the wait-for-IDR recovery path.

**Stream-format coverage.** H.264 (8-bit and 4:4:4), HEVC (Main / Main10 / RExt
4:4:4), AV1 (Main / Main10 / High 4:4:4). The default set is not a hardcoded
list: `VideoFormats.probedSupported` (`Types.swift`) asks
`VTIsHardwareDecodeSupported` per codec at runtime, with an Apple-Silicon gate
on the 4:4:4 profiles, and the per-host `HostCodecPreference` narrows it
further. Codec negotiation then goes through
`BackendStreamConfig.supportedVideoFormats` (our preferences) and
`BackendServerInfo.serverCodecModeRaw` (raw `SCM_*` bitmask from `/serverinfo`,
passed verbatim - see the landmine note in `StreamProtocolConstants.swift` for
why we don't remap it).

## Input forwarding

`InputForwarder` (`Glimmer/Stream/InputForwarder.swift`, plus the
`ControllerForwarder` extension) hooks events at the responder level via a
custom `StreamInputView` installed as the stream window's first responder.
Earlier revisions used `NSEvent.addLocalMonitorForEvents`, but macOS 26's
responder chain consumes events for content views that accept first responder
before the local-monitor block fires.

All uplink goes through the `StreamingBackend` send methods (`sendKeyboard` /
`sendMouseMove` / `sendMultiController` / ...), which the native engine batches
(`InputBatcher`, ~1ms merge+flush) onto the reliable control channel.

**Mouse.** `CGAssociateMouseAndMouseCursorPosition(false)` freezes the OS cursor
at its current position the moment the window becomes key. Raw HID deltas come
from the underlying `CGEvent`'s `kCGMouseEventDeltaX/Y` fields
(`NSEvent.deltaX/Y` goes to zero when the cursor is frozen). A sub-pixel
residual accumulator carries fractional motion forward so slow trackpad moves
don't round to zero. Cursor warp to screen center before associate-false defends
against hot corners triggering during a stream - there's no public API to
disable hot corners, so the workaround is keeping the frozen cursor away from
them.

**Keyboard.** Positional scancodes via `sendKeyboard`, with the high bit
(`0x8000`) set to ask the host to skip layout correction (GFE otherwise remaps
AZERTY → QWERTY; we want the user's physical key position to win). Every
physical key-down / key-up emits one keyboard event - no per-event modifier
reset, no "release before press" coalescing. NKRO works because AppKit delivers
each transition as its own `NSEvent` and the responder chain hands each to
`keyDown(with:)` / `keyUp(with:)` independently. Stuck modifiers are released
when the window loses focus, when Picture in Picture starts, and as a stream ends
(before the connection closes). Modifier keys are tracked per physical key,
left and right apart (`ModifierKeyTracker`).

The Cmd key reports as `VK_LWIN` / `VK_RWIN`. By default
(`captureSysKeys == false`) the InputForwarder drops Cmd-bearing keyDown and
`.command` `flagsChanged` events so ⌘-Tab, ⌘-Space, ⌘-Q stay local-Mac chords.
`captureSysKeys = true` forwards everything as a Win-key chord. The configured
quit / stats hotkeys are detected before the captureSysKeys gate so a
Cmd-bearing quit chord (default ⌃⌘Q) keeps working in either mode.

**Controller.** GameController framework. `GCControllerDidConnect` /
`Disconnect` are observed; per-controller state is kept in
`attachedControllers: [ObjectIdentifier: AttachedController]`. Slot assignment
is a 16-bit `gamepadMask` - bit N == 1 means slot N is in use. Arrival is
announced via `sendControllerArrival` with probed capabilities (some Sunshine
builds silently drop multi-controller events without it). State updates go
through `sendMultiController`. Host-driven feedback comes back through
`ConnectionEvents`: rumble (`0x010b`), trigger rumble (`0x5500`), motion-sensor
enable (`0x5501` - answered with `sendControllerMotion` samples), and RGB
lightbar (`0x5502`); `ControllerHaptics`, `ControllerMotion`, and
`ControllerBattery` own the actuator/sampler sides.

**Gesture suppression.** An `NSEvent.addLocalMonitorForEvents` for the narrow
mask `[.magnify, .smartMagnify, .swipe, .rotate]` swallows that gesture family
while the stream window is key. The broader gesture/pressure types (`.gesture` /
`.beginGesture` / `.endGesture` / `.pressure`) are deliberately EXCLUDED: they
carry the trackpad pan/scroll the OS synthesizes `mouseMoved` from, so
swallowing them would kill cursor + scroll on trackpad-only Macs. Scroll wheel
is NOT swallowed - scrolls forward as host scroll events. macOS Accessibility
Zoom chords (⌥⌘8 / ⌥⌘= / ⌥⌘-) are intercepted unconditionally so they never
reach the OS while a stream is up.

**Input gating.** The engine refuses input until the control channel is up: the
backend's `send*` methods return -2 before then (mirroring upstream
`InputStream.c`'s `initialized` guard). `InputForwarder.isReady` flips true when
`connectionStarted` fires; until then events drop on the floor instead of
flooding the log with -2s.

## Window model

`StreamWindow` (`Glimmer/Stream/StreamWindow.swift` + extensions). One titled
`NSWindow` per session; full screen is macOS's own (green button / ⌃⌘F into a
Space, `StreamWindow+FullScreen.swift`), remembered between streams
(`StreamFullScreenMemory`). There are no key/activation observers: the window
stays where it is when another app is clicked.

**Display layer as root.** `AVSampleBufferDisplayLayer` is installed as the
content view's root layer (`view.layer = layer` BEFORE
`view.wantsLayer = true`), not a sublayer of a default backing layer.
Compositing through an intermediate sRGB layer flattens EDR back to SDR before
the panel sees it. The stats overlay is a sublayer of the display layer.

**Present suppression.** `publishPresentSuppression` is the single place that
decides whether anything can be seen: hidden or miniaturized with no Picture in
Picture, PiP paused, or every display asleep → suppressed. The decoder then
keeps only the newest frame and, after 2 s, stops decoding (the host can't
pause; receive, FEC and audio continue); coming back does one keyframe resync.

**Picture in Picture.** Owned by the app, not by a stream
(`PictureInPictureStage`): ONE `AVPictureInPictureController` on ONE layer
(`PiPSource`, an invisible window of its own that the decoder mirrors frames
into), reused by every stream. A stream window claims the stage when it enters
PiP and releases it when it closes. Never build a second controller on that
layer or drop the controller while the layer lives - AVKit ties the layer to
its controller without retaining it (a crash, 2026-11-16). Closing uses the
PiP window's own × animation via a private AVKit call, with a public-API
fallback (`StreamPictureInPicture`). `PiPPanelFitter` keeps the picture whole
inside Apple's PiP window.

**Switch PC.** Never in place: the playing stream closes (its window or its
PiP) and the next opens the same way (`AppModel.switchHost`,
`startPendingHostSwitch`).

**`NSWindow.sharingType`** = `.readOnly`. The stream window can be captured by
ScreenCaptureKit, `screencapture(1)` and recording / conferencing apps. glimmer
used `.none`; Shimmer allows capture because Picture in Picture mirrors this
window's layer and stopped when a recording started. See `SECURITY.md` →
Runtime hardening.

## Agent control

`AgentControl` (`Glimmer/AgentControl.swift`) publishes the app's state to
`~/Library/Application Support/Shimmer/agent-state.json` and takes a small
allowlist of commands as JSON files dropped in `agent-commands/` (mode 0700);
`scripts/shimmerctl` is the CLI over both. See [CLI.md](CLI.md).

## Crossing isolation - receive threads ↔ Swift actors

The native engine delivers frames, audio, and control events on its own receive
threads - threads neither the actor system nor `@MainActor` knows about, and the
latency cost of round-tripping every frame through an actor is unacceptable. The
bridge handles this:

- **`StreamBridgeContext`** (`Glimmer/Stream/StreamBridgeContext.swift`) is the
  single instance allocated per session. It holds _weak_ references to the
  session and every subsystem, plus the `AsyncStream<StreamEvent>.Continuation`.
  A subsystem torn down before the receive threads drain just becomes nil at the
  callback site - no UAF, no order dependency.
- `Unmanaged.passRetained(bridge)` keeps the bridge alive across the
  connection's lifetime regardless of which subsystem nils out.
- **`StreamBridgeContext.current`** is a weak static, guarded by a lock, for
  context-less callback paths. Single in-flight session means a single global
  slot is correct.
- **Event yield.** Receive-thread callbacks yield directly through
  `bridge.eventContinuation?.yield(...)`. `AsyncStream.Continuation` is Sendable
  and FIFO-ordered, so ordering of consecutive callbacks is preserved on the
  consumer side. The previous `Task { await deliver(...) }` pattern lost
  ordering because unstructured Tasks land on the global concurrent executor
  without inter-Task happens-before - `stageStarting` and `stageComplete`
  arriving back-to-back from a receive thread could surface in either order on
  the consumer side.

**Swift 6 strict concurrency posture.** `SWIFT_STRICT_CONCURRENCY = complete` on
every configuration. Where the alternative is "synthesize an actor hop the hot
path can't afford," we use `nonisolated(unsafe)` with the invariant documented
at the property and the synchronisation justified inline. Examples:

- `StreamBridgeContext.session/videoDecoder/audioDecoder/inputForwarder` are
  weak refs; Swift's weak storage is atomic per spec, and the engine serialises
  its callbacks per-stream.
- `VideoDecoder._displayLayer` is guarded by an `NSLock` (the layer itself is
  `AVSampleBufferDisplayLayer.enqueue`-thread-safe per Apple's header, but the
  pointer load/store races against MainActor's nil-out on teardown).
- `VideoDecoder.decompressionSession` / `formatDescription` / SPS / PPS / VPS /
  stream parameters all live on `decodeQueue` and are serialised by it.

See `docs/CONTRIBUTING.md` for the rule on when `nonisolated(unsafe)` is
acceptable.

## Identity & pairing

`Identity.swift`: per-machine 32-hex `uniqueID`, an RSA-2048 keypair, and a
20-year self-signed cert (CN `NVIDIA GameStream Client` - every GameStream
client identifies as this string). Three mode-0600 files under
`~/Library/Application Support/Glimmer/Identity/`:

- `client-cert.pem`
- `client-key.pem`
- `client-uniqueid.txt`

Not the keychain. The top-of-file comment in `Identity.swift` explains why:
adhoc-signed builds re-derive their CDHash on every rebuild, the keychain ACL
pins to the CDHash, every rebuild trips a "Glimmer wants to use its key" prompt.
Files don't have that problem. Mode 0600 + atomic writes + stat-after-chmod
verification (some FUSE / NFS backends silently ignore the chmod).

`Pairing.swift`: the GameStream PIN handshake, five HTTP rounds plus a final
HTTPS liveness check. AES-128-ECB on raw 16-byte buffers (no padding - the
protocol pre-sizes its blocks) keyed off `SHA-256(salt || PIN)[0..16]` (or SHA-1
for pre-Gen-7 GFE, which we detect from `appversion` but don't expect to
encounter on Sunshine). RSA signatures using the long-lived client cert prove
possession of the private key.

Critically: the host cert is pinned (`NetworkClient.setPinnedHostCert`) ONLY
after the RSA signature in step 5 verifies AND the PIN-correctness check passes.
`NetworkClient.fetchServerInfo` will NOT auto-pin on first contact. Threat-model
details and the pinning lifecycle live in [SECURITY.md](SECURITY.md).

## Build pipeline

The Sunshine engine compiles as part of the app target. The PS5 path links
`libchiaki`, built by `scripts/build-libchiaki.sh` from the
`third_party/chiaki-ng` submodule with the patches in
`third_party/chiaki-ng-patches/` applied to copies (the submodule stays
pristine). The other external link dependencies are Homebrew `openssl@3` and
`opus`; `make dist` copies their dylibs into `Contents/Frameworks` (rewired to
`@rpath`), so the shipped app is self-contained and needs nothing installed to
run.

### `Glimmer/StreamLib.xcconfig`

Tells Xcode where the OpenSSL/Opus headers and libraries live, and pulls in the
version single-source-of-truth:

```
#include "Version.xcconfig"
HEADER_SEARCH_PATHS  = $(inherited) $(GLIMMER_REPO_ROOT) \
                      $(OPENSSL_PREFIX)/include $(OPUS_PREFIX)/include
LIBRARY_SEARCH_PATHS = $(inherited) $(OPENSSL_PREFIX)/lib $(OPUS_PREFIX)/lib
OTHER_LDFLAGS        = $(inherited) -lssl -lcrypto -lz -lopus
ARCHS                = arm64
SWIFT_OBJC_BRIDGING_HEADER = $(SRCROOT)/Glimmer-Bridging-Header.h
```

`OPENSSL_PREFIX` and `OPUS_PREFIX` are injected by the Makefile from
`brew --prefix` so the pbxproj stays portable. `ARCHS = arm64` is pinned because
Homebrew's `openssl@3` and `opus` are arm64-only, so a universal link fails on
the x86_64 slice. `Glimmer/Version.xcconfig` is the single source of truth for
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` - the version is NOT set in
`project.pbxproj`.

### `Makefile`

Every build below Release-publish goes through the same pipeline the shipped
build does, so there is no adhoc/Debug divergence in signing, notarization, or
library validation to chase. Without a Developer ID cert on the machine the
pipeline falls back to an adhoc Release build.

| Target                   | What it does                                                 |
| ------------------------ | ------------------------------------------------------------ |
| `make app`               | Compile-only check, no signing or notarization               |
| `make test`              | Build + run the `GlimmerTests` bundle                        |
| `make release`           | Notarized Release build, no install                          |
| `make` / `make install`  | `release` + copy to `/Applications/Glimmer.app`              |
| `make reinstall`         | `install` + quit and relaunch the running app                |
| `make dev`               | Inner loop: `test`, then `reinstall`                         |
| `make profile`           | Launch under Instruments (Time Profiler)                     |
| `make profile-signposts` | Launch under Instruments (Logging template)                  |
| `make dist`              | Clean Release → Developer ID sign → notarize → staple → DMG  |
| `make release-publish`   | `dist` + EdDSA-signed ZIP → GitHub release + Sparkle appcast |
| `make uninstall`         | Remove `/Applications/Glimmer.app`                           |
| `make clean`             | `rm -rf build/`                                              |

Signing and notarization details (the dedicated signing keychain, the notary
profile, the credentials file) are documented in the Makefile itself and in
[RELEASE.md](RELEASE.md).
