//
//  AppModel+StreamAudio.swift
//
//  The stream's own volume, set by the menu bar's slider, and the plumbing
//  that pushes a change onto the live session's audio player node. The stored
//  property lives in AppModel.swift (it has to); everything about WHEN a volume
//  applies lives here, and everything about HOW it applies lives in
//  AudioDecoder+Engine.swift.
//
//  One control, the way the Sound menu does it: a slider from silence to full,
//  no separate mute (Kevin, 2026-11-18). Silent is the slider at the left.
//

import Foundation

extension AppModel {
    /// Seed for `streamVolume`. `UserDefaults.double(forKey:)` answers 0 for an
    /// absent key, which would start every fresh install silent - so probe for
    /// the object first and only then trust the number. A Mac that was muted
    /// under the old Mute item opens silent, as it was: the slider at the left.
    nonisolated static func loadStreamVolume(_ defaults: UserDefaults = .standard) -> Double {
        if defaults.object(forKey: retiredMuteKey) != nil {
            let wasMuted = defaults.bool(forKey: retiredMuteKey)
            defaults.removeObject(forKey: retiredMuteKey)
            if wasMuted {
                defaults.set(0.0, forKey: "streamVolume")
                return 0
            }
        }
        guard let stored = defaults.object(forKey: "streamVolume") as? Double else { return 1.0 }
        return min(max(stored, 0), 1)
    }

    /// The old Mute item's persisted state, read once to carry it over.
    nonisolated static let retiredMuteKey = "streamMuted"

    /// Push the current volume onto the live session. A no-op when nothing is
    /// streaming, and that's fine: `AudioDecoder` re-reads the stored value
    /// every time it builds its graph, and `startStream` pushes it once more at
    /// session start, so the next stream opens at the right level either way.
    func applyStreamVolume() {
        nativeSession?.audioDecoder.setOutputVolume(Float(streamVolume))
    }

    /// The slider moved. Clamped to 0...1; a move under half a percent is not
    /// written (a drag sends dozens a second, each a lock on the audio graph).
    func setStreamVolume(_ level: Double) {
        let clamped = min(max(level, 0), 1)
        guard abs(clamped - streamVolume) >= 0.005 || clamped == 0 || clamped == 1 else { return }
        streamVolume = clamped
    }
}
