//
//  HostSwitchTests.swift
//
//  Switch PC never swaps the picture in place: the stream that's playing
//  closes - its Picture in Picture window or its stream window - and the new
//  one opens the same way, fresh.
//

import Foundation
import Testing
@testable import Glimmer

@MainActor
struct HostSwitchTests {
    private func host(_ id: String) -> Glimmer.Host {
        Glimmer.Host(id: id, name: id, customName: nil, localAddress: nil, manualAddress: nil,
                     apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil,
                     gfeVersion: nil, macAddress: nil)
    }

    @Test func switchingInPictureInPictureClosesItAndReopens() {
        let model = AppModel()
        model.isStreaming = true
        model.activeStreamHostID = "tower"
        model.nativeStreamPictureInPicture = true
        defer { StreamWindow.switchingHosts = false }
        model.switchHost(to: host("den"))
        // No second stream connecting behind the first, no PiP held open.
        #expect(model.standbyStream == nil)
        #expect(!PictureInPictureStage.shared.isHolding)
        // The old stream ends; the new one opens in Picture in Picture.
        #expect(model.pendingHostSwitch?.hostID == "den")
        #expect(model.pendingHostSwitch?.inPictureInPicture == true)
    }

    @Test func switchingInAWindowClosesItAndReopens() {
        let model = AppModel()
        model.isStreaming = true
        model.activeStreamHostID = "tower"
        model.nativeStreamPictureInPicture = false
        defer { StreamWindow.switchingHosts = false }
        model.switchHost(to: host("den"))
        #expect(model.pendingHostSwitch?.hostID == "den")
        #expect(model.pendingHostSwitch?.inPictureInPicture == false)
    }
}
