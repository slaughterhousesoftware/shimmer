//
//  StreamSession+PlayStation.swift
//
//  The PS5 connect step: what connectBackend does for Sunshine, minus the host
//  session to cancel on failure (a PS5 has no /launch to undo).
//

import Foundation
import os

extension StreamSession {
    func connectPlayStation(
        _ backend: PlayStationBackend,
        backendConfig: BackendStreamConfig,
        setup: (StreamWindow, InputForwarder, VideoDecoder)
    ) async throws {
        let console = backend.console
        connectFlowState = OSSignposter.network.beginInterval(
            "ConnectFlow", id: connectFlowSignpostID, "host=\(console.address, privacy: .private)")
        telemetryServerName = console.nickname
        anchorTelemetryConnectStart(hostAddress: console.address)
        AudioDecoder.seedPlayStationCushion(host: console.address)

        backend.attachVideoSink(setup.2)
        backend.attachAudioSink(audioDecoder)

        let server = BackendServerInfo(
            address: console.address, appVersion: "", gfeVersion: "",
            rtspSessionUrl: "", serverCodecModeRaw: 0)
        do {
            try await backend.startConnectionAsync(server: server, config: backendConfig)
        } catch {
            let stoppedByRequest = stopRequested
            if !stoppedByRequest { noteTelemetryDisconnect(.connectFailed) }
            await performStop(cause: stoppedByRequest ? .userStopped : .connectFailed)
            throw stoppedByRequest ? StreamError.cancelled : error
        }
    }
}

extension AudioDecoder {
    /// The PS5 sends 10 ms audio frames in bursts: measured on the home LAN,
    /// gaps of 35-60 ms every second or two and the odd 100 ms one, where
    /// Sunshine's 5 ms packets arrive evenly. The adaptive cushion starts at
    /// 30 ms and learns per host, so a first PS5 session under-runs while it
    /// learns. Before each PS5 session, lift this console's memory to at least
    /// these values; the cushion still grows from there when the link needs it.
    static let playStationCushionTargetMs: Double = 70
    static let playStationCushionFloorMs: Double = 50

    static func seedPlayStationCushion(host: String) {
        for link in ["wifi", "wired"] {
            let key = cushionMemoryKey(host: host, link: link)
            let stored = readCushionMemory(key: key)
            let target = max(stored?.targetMs ?? 0, playStationCushionTargetMs)
            let floor = max(stored?.floorMs ?? 0, playStationCushionFloorMs)
            guard stored?.targetMs != target || stored?.floorMs != floor else { continue }
            persistCushionMemory(key: key, targetMs: target, floorMs: floor)
        }
    }
}
