//
//  AppModel+StreamHandover.swift
//
//  Switch PC in Picture in Picture, both streams up: the game you're playing
//  stays live and playable while the next PC connects in standby behind it
//  (StreamSession.standby - hidden, silent, no pad), then a one-frame cut in
//  the same PiP window:
//
//    1. the old stream stops feeding the PiP (atomically - no late frame);
//    2. the pad leaves the old stream (slots are released by number, so
//       before the new one attaches);
//    3. the PiP layer is flushed keeping its picture, and the new stream
//       feeds it;
//    4. the new stream's window takes PiP over in place;
//    5. the new stream gets the pad, the controller's feedback
//       (ControllerFocus) and the volume;
//    6. the old stream is retired: its teardown changes nothing that is now
//       the new stream's.
//
//  If the next PC fails to connect, the game you're playing just carries on.
//  Streams are told apart by token: AppModel's live state follows only
//  `currentStreamToken`.
//

import AppKit
import Foundation

extension AppModel {

    // MARK: - Routing by stream

    /// A stream's event: the live stream's go to `handleNativeEvent`, a
    /// standby stream's are noted for its takeover, a retired one's dropped.
    func route(_ event: StreamEvent, host: Host, token: UUID) {
        if token == currentStreamToken {
            handleNativeEvent(event, host: host)
            return
        }
        guard var next = standbyStream, next.token == token else { return }
        switch event {
        case let .streamFormat(width, height, fps, _):
            next.width = width; next.height = height; next.fps = fps
        case .hdrActive(let active):
            next.hdr = active
        case .firstFrame:
            guard !next.promoting else { return }
            next.promoting = true
            Task { [weak self] in
                // A few frames in, so it is steady when it goes on screen.
                try? await Task.sleep(for: .milliseconds(100))
                await self?.promoteStandbyStream(token: token)
            }
        default:
            break
        }
        standbyStream = next
    }

    /// A stream ended: the live one cleans up as always; a standby one that
    /// never took over just goes (the game in play carries on); a retired one
    /// leaves nothing behind.
    func finishSession(host: Host, caughtError: Error?, token: UUID) {
        if token == currentStreamToken {
            cleanupAfterStream(host: host, caughtError: caughtError)
            return
        }
        if let next = standbyStream, next.token == token {
            standbyStream = nil
            ControllerFocus.abandon(next.backendID)
            let reason = caughtError.map { ($0 as NSError).localizedDescription } ?? "it ended"
            Diag.error("Switch: \(host.displayName, privacy: .private) didn't connect (\(reason, privacy: .private)) "
                + "- staying on the current stream", "Stream")
            nativeStreamError = "Couldn't switch to \(host.displayName)."
            reselectLiveHost()
            return
        }
        if cancelledStandbyTokens.remove(token) != nil {
            Diag.info("Switch: the cancelled connection to \(host.displayName, privacy: .private) closed", "Stream")
            return
        }
        recordStreamActivity(for: host.id)
        Diag.info("Switch: the previous stream (\(host.displayName, privacy: .private)) closed", "Stream")
    }

    // MARK: - Standby

    /// Connect to `host` behind the live stream, which keeps playing.
    func startStandbyStream(on host: Host) {
        guard isStreaming, activeStreamHostID != host.id else { return }
        let name = UserDefaults.standard.string(forKey: Self.lastPlayedAppKey(for: host.id)) ?? ""
        guard let app = Self.resolveHeroApp(in: host.apps, named: name) else { return }
        cancelStandbyStream(reason: "another PC picked")
        Diag.notice("Switch: connecting to \(host.displayName, privacy: .private) · \(app.name) in the background "
            + "- the current stream keeps playing", "Stream")
        let cfg = sessionStreamConfig(for: host, app: app)
        launchSession(app: app, host: host, cfg: cfg, info: nativeServerInfo(for: host),
                      token: UUID(), standby: true)
    }

    /// Stop a standby stream that hasn't taken over (End Stream, the live
    /// stream ending, another PC picked, back to the current PC).
    func cancelStandbyStream(reason: String) {
        guard let next = standbyStream else { return }
        standbyStream = nil
        cancelledStandbyTokens.insert(next.token)
        ControllerFocus.abandon(next.backendID)
        Diag.notice("Switch to \(next.host.displayName, privacy: .private) cancelled (\(reason, privacy: .public))",
                    "Stream")
        Task { await next.session.stop() }
    }

    /// The menu's selection follows the stream actually playing.
    private func reselectLiveHost() {
        guard let live = hosts.first(where: { $0.id == activeStreamHostID }), selectedHost?.id != live.id else { return }
        selectHost(live)
    }

    // MARK: - The cut-over

    func promoteStandbyStream(token: UUID) async {
        guard let next = standbyStream, next.token == token, isStreaming, let old = nativeSession else { return }
        let outgoing = await old.handoverParts()
        let incoming = await next.session.handoverParts()
        // Re-check after the hops: anything may have ended meanwhile.
        guard standbyStream?.token == token, nativeSession === old, isStreaming,
              let window = incoming.window, let input = incoming.input, let decoder = incoming.decoder
        else { return }
        let stage = PictureInPictureStage.shared

        // 1-2. The old stream lets go of the PiP layer and the pad. The pad's
        // raw-HID link is held open across the hand-off: closed and reopened,
        // it takes a moment to know the pad is on Bluetooth again, and the
        // PS5's haptics look for it right at the cut.
        DualSenseHID.shared.retain()
        defer { DualSenseHID.shared.release() }
        outgoing.decoder?.setMirrorLayer(nil)
        outgoing.input?.releaseGamepadsForHandover()
        let handedOff = outgoing.window?.handOffPictureInPicture() ?? false
        outgoing.window?.handsOffToLauncher = false

        // 3-4. The new stream's frames replace the old picture in place.
        if handedOff {
            stage.prepareForNextStream()
            decoder.setMirrorLayer(stage.source.layer)
            _ = window.adoptHeldPictureInPicture()
        } else {
            decoder.setMirrorLayer(window.pipLayer)
        }

        // 5. Pad, controller feedback, sound.
        if let oldInput = outgoing.input { input.inheritBackgroundControllerFlag(from: oldInput) }
        input.enableGamepads()
        ControllerFocus.promote(next.backendID)

        // AppModel's live state is the new stream's from here.
        currentStreamToken = next.token
        nativeSession = next.session
        standbyStream = nil
        activeStreamApp = next.app
        activeStreamHostID = next.host.id
        activeStreamHasVideo = true
        activeStreamWidth = next.width; activeStreamHeight = next.height; activeStreamFps = next.fps
        nativeHDRActive = next.hdr
        nativeStreamError = nil
        streamPhase = .streaming
        UserDefaults.standard.set(next.app.name, forKey: Self.lastPlayedAppKey(for: next.host.id))
        applyStreamVolume()
        markStreamVideo(for: next.host.id)
        noteStreamLiveForAWDL()
        if selectedHost?.id != next.host.id, let host = hosts.first(where: { $0.id == next.host.id }) {
            selectHost(host)
        }
        let ms = Int(Date().timeIntervalSince(next.startedAt) * 1000)
        Diag.notice("Switch: \(next.host.displayName, privacy: .private) took over \(ms) ms after the switch "
            + (handedOff ? "- same Picture in Picture window" : "- the old stream wasn't in Picture in Picture"),
            "Stream")
        if !handedOff, !nativeStreamBackgrounded {
            // The old stream's window had come back meanwhile: show this one's.
            StreamWindow.forceActivate()
            resumeStreamWindow()
        }
        await next.session.promoteFromStandby()

        // 6. Retire the old stream.
        await old.stop()
    }
}
