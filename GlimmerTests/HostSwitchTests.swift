//
//  HostSwitchTests.swift
//
//  Switch PC never swaps the picture in place: the stream that's playing
//  closes - its Picture in Picture window or its stream window - and the new
//  one opens the same way, fresh.
//

import AppKit
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
        // The old stream ends (its PiP closes); the new one opens its own.
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

/// Closing a stream's PiP looks like its ×: the picture shrinks into its
/// centre (to half size) while fading.
struct PiPCloseAnimationTests {
    @Test func endsAtHalfSizeAroundTheSameCentre() {
        let pip = NSRect(x: 20, y: 110, width: 442, height: 249)
        let end = PictureInPictureStage.closedFrame(of: pip)
        #expect(end.width == 221)
        #expect(end.height == 124.5)
        #expect(end.midX == pip.midX)
        #expect(end.midY == pip.midY)
    }
}
