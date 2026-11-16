//
//  StreamSession+Handover.swift
//
//  Switch PC in Picture in Picture, with both streams up for the moment it
//  takes: the next stream connects in STANDBY (`standby`, set before start)
//  behind the live one - hidden, silent, no pad, no pacer, nothing fed to the
//  PiP - and AppModel promotes it at the cut-over, when its first frames are
//  decoded. The live stream keeps playing (and keeps the pad) until then.
//

import AppKit

extension StreamSession {

    /// The main-actor parts the cut-over moves between the two streams.
    func handoverParts() -> (window: StreamWindow?, input: InputForwarder?, decoder: VideoDecoder?) {
        (window, input, videoDecoder)
    }

    /// Standby over: this is the stream now. Stand up what standby left out -
    /// the frame pacer (on a screen link: the stream is in PiP) and the
    /// present watchdog and metric.
    func promoteFromStandby() async {
        guard standby else { return }
        standby = false
        let fps = configuredFps
        if let win = window, let dec = videoDecoder {
            await MainActor.run {
                dec.startPacing(drivingView: win.streamContentView, configuredFps: fps)
            }
        }
        guard isStreaming, !stopInProgress else { return }
        await startPresentWatchdog()
        guard isStreaming, !stopInProgress else { return }
        await startPresentMetricTimer()
    }
}
