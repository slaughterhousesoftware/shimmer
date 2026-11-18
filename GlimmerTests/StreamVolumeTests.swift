//
//  StreamVolumeTests.swift
//
//  The menu bar's stream volume: one slider, 0 (silent) to full, no separate
//  mute. Guarded here: an absent `streamVolume` key reads as FULL volume, not
//  silence (`double(forKey:)` answers 0 for a missing key, which would ship
//  every fresh install silent); a Mac muted under the old Mute item opens
//  silent rather than suddenly loud; and a drag's tiny moves are not written.
//

import Testing
@testable import Glimmer

/// Serialized and defaults-restoring for the same reason QualityRestoreTests is:
/// `AppModel()` reads and writes `UserDefaults.standard` under the test host.
@Suite(.serialized)
struct StreamVolumeTests {

    private static let keys = ["streamVolume", AppModel.retiredMuteKey]

    private func withSeededDefaults(_ seed: [String: Any], _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = Self.keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for key in Self.keys { defaults.removeObject(forKey: key) }
        for (key, value) in seed { defaults.set(value, forKey: key) }
        body()
    }

    @Test func aFreshInstallStartsAtFullVolume() {
        withSeededDefaults([:]) { #expect(AppModel.loadStreamVolume() == 1.0) }
    }

    @Test func aSavedLevelIsRestoredAsItself() {
        withSeededDefaults(["streamVolume": 0.4]) { #expect(AppModel.loadStreamVolume() == 0.4) }
    }

    @Test func anOutOfRangeSavedLevelIsClamped() {
        withSeededDefaults(["streamVolume": 4.2]) { #expect(AppModel.loadStreamVolume() == 1.0) }
        withSeededDefaults(["streamVolume": -1.0]) { #expect(AppModel.loadStreamVolume() == 0) }
    }

    /// Muted at 10% under the old menu: still silent now, the slider at the
    /// left - not 10% audio out of nowhere. The old key is gone afterwards.
    @Test func aMacThatWasMutedOpensSilent() {
        withSeededDefaults(["streamVolume": 0.1, AppModel.retiredMuteKey: true]) {
            #expect(AppModel.loadStreamVolume() == 0)
            #expect(UserDefaults.standard.object(forKey: AppModel.retiredMuteKey) == nil)
            #expect(AppModel.loadStreamVolume() == 0)
        }
        withSeededDefaults(["streamVolume": 0.6, AppModel.retiredMuteKey: false]) {
            #expect(AppModel.loadStreamVolume() == 0.6)
            #expect(UserDefaults.standard.object(forKey: AppModel.retiredMuteKey) == nil)
        }
    }

    @MainActor @Test func theSliderSetsTheLevelAllTheWayToSilence() {
        withSeededDefaults([:]) {
            let model = AppModel()
            model.setStreamVolume(0.37)
            #expect(model.streamVolume == 0.37)
            model.setStreamVolume(-3)
            #expect(model.streamVolume == 0)
            model.setStreamVolume(2)
            #expect(model.streamVolume == 1)
        }
    }

    /// A drag sends dozens of values a second; one under half a percent from
    /// the current level is dropped (each write locks the audio graph).
    @MainActor @Test func aDragsTinyMovesAreNotWritten() {
        withSeededDefaults([:]) {
            let model = AppModel()
            model.setStreamVolume(0.5)
            model.setStreamVolume(0.502)
            #expect(model.streamVolume == 0.5)
            model.setStreamVolume(0.51)
            #expect(model.streamVolume == 0.51)
        }
    }
}
