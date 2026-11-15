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

        backend.attachVideoSink(setup.2)
        backend.attachAudioSink(audioDecoder)

        let server = BackendServerInfo(
            address: console.address, appVersion: "", gfeVersion: "",
            rtspSessionUrl: "", serverCodecModeRaw: 0)
        do {
            try await backend.startConnectionAsync(server: server, config: backendConfig)
        } catch {
            noteTelemetryDisconnect(.connectFailed)
            await stop()
            throw error
        }
    }
}
