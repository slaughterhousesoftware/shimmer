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

    /// Selecting a machine writes the selection, that machine's settings and
    /// the global mirror of them - and these tests run inside Shimmer.app, so
    /// UserDefaults.standard is the real app's. Each test puts back what it
    /// moved (it used to leave "den" selected on the machine that ran it).
    private static let touchedKeys = ["glimmer.selectedHostID", "qualityPreset", "customWidth", "customHeight",
                                      "customFPS", "bitrateAuto", "manualBitrateMbps", "customHDR",
                                      "quitAppWhenStreamEnds", HostStreamSettings.storageKey(for: "den"),
                                      HostStreamSettings.storageKey(for: "attic"),
                                      HostStreamSettings.storageKey(for: "tower"),
                                      "glimmer.codecPreference.den", "glimmer.codecPreference.attic",
                                      "glimmer.codecPreference.tower", "pipLaunchRequestedAt"]

    private func preservingAppDefaults(_ body: () -> Void) {
        let d = UserDefaults.standard
        let saved = Self.touchedKeys.map { ($0, d.object(forKey: $0)) }
        defer { for (key, value) in saved { d.set(value, forKey: key) } }
        body()
    }

    @Test func switchingLeavesTheAppsOwnDefaultsAlone() {
        let d = UserDefaults.standard
        let before = Self.touchedKeys.map { d.object(forKey: $0) as? NSObject }
        preservingAppDefaults {
            let model = AppModel()
            model.isStreaming = true
            model.activeStreamHostID = "tower"
            defer { StreamWindow.switchingHosts = false }
            model.switchHost(to: host("den"))
        }
        #expect(Self.touchedKeys.map { d.object(forKey: $0) as? NSObject } == before)
    }

    @Test func switchingInPictureInPictureClosesItAndReopens() { preservingAppDefaults {
        let model = AppModel()
        model.isStreaming = true
        model.activeStreamHostID = "tower"
        model.nativeStreamPictureInPicture = true
        defer { StreamWindow.switchingHosts = false }
        model.switchHost(to: host("den"))
        // The old stream ends (its PiP closes); the new one opens its own.
        #expect(model.pendingHostSwitch?.hostID == "den")
        #expect(model.pendingHostSwitch?.inPictureInPicture == true)
    } }

    /// Picking another machine while the old stream is still closing changes
    /// where the next one opens. It used to be ignored, and then the cleanup
    /// found the selection no longer matched: the stream ended and nothing
    /// started.
    @Test func aSecondPickWhileTheOldStreamClosesRetargetsTheSwitch() { preservingAppDefaults {
        let model = AppModel()
        model.isStreaming = true
        model.activeStreamHostID = "tower"
        defer { StreamWindow.switchingHosts = false }
        model.switchHost(to: host("den"))
        #expect(StreamWindow.switchingHosts)
        model.switchHost(to: host("attic"))
        #expect(model.pendingHostSwitch?.hostID == "attic")
        // Back to the machine that was playing: it reopens there.
        model.switchHost(to: host("tower"))
        #expect(model.pendingHostSwitch?.hostID == "tower")
    } }

    /// The switch opens on the machine it was asked for, whatever page is
    /// being looked at when the old stream finishes closing.
    @Test func theSwitchGoesWhereItWasAsked() { preservingAppDefaults {
        let model = AppModel()
        let den = host("den")
        model.hosts = [host("tower"), den]
        model.selectedHost = model.hosts[0]
        model.startPendingHostSwitch(.init(hostID: "den", inPictureInPicture: true, requestedAt: Date()))
        #expect(model.selectedHost?.id == "den")
        // Too late is still too late.
        model.selectedHost = model.hosts[0]
        model.startPendingHostSwitch(.init(hostID: "den", inPictureInPicture: true,
                                           requestedAt: Date().addingTimeInterval(-AppModel.hostSwitchWindowSeconds - 1)))
        #expect(model.selectedHost?.id == "tower")
    } }

    @Test func switchingInAWindowClosesItAndReopens() { preservingAppDefaults {
        let model = AppModel()
        model.isStreaming = true
        model.activeStreamHostID = "tower"
        model.nativeStreamPictureInPicture = false
        defer { StreamWindow.switchingHosts = false }
        model.switchHost(to: host("den"))
        #expect(model.pendingHostSwitch?.hostID == "den")
        #expect(model.pendingHostSwitch?.inPictureInPicture == false)
    } }
}
