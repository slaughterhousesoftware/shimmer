//
//  PlayStationSettings.swift
//
//  The PS5's own stream settings, apart from the Sunshine ones: a PS5 stream
//  is a different kind of stream (fixed 720p/1080p presets, 30/60 fps, its
//  own bitrate range, the DualSense's haptics and triggers), so it gets its
//  own Settings tab instead of borrowing numbers meant for a PC.
//  Persisted under "PS5." keys.
//

import Foundation
import Observation

@MainActor
@Observable
final class PlayStationSettings {

    static let shared = PlayStationSettings()

    enum HapticsMode: String, CaseIterable, Identifiable, Sendable {
        /// The console's haptics on the DualSense's actuators (USB or Bluetooth).
        case actuators
        /// Haptics turned into plain rumble.
        case rumble
        case off

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .actuators: return "Haptic feedback"
            case .rumble: return "Rumble"
            case .off: return "Off"
            }
        }
    }

    enum Presentation: String, CaseIterable, Identifiable, Sendable {
        /// Each frame shown as soon as it is decoded.
        case lowestLatency
        /// Frames released on the display's clock (Shimmer's frame pacer).
        case smooth

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .lowestLatency: return "Lowest latency"
            case .smooth: return "Smooth"
            }
        }
    }

    enum Upscaling: String, CaseIterable, Identifiable, Sendable {
        case off, upTo1440p, upTo4K

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .off: return "Off"
            case .upTo1440p: return "Up to 1440p"
            case .upTo4K: return "Up to 4K"
            }
        }
        /// The largest output allowed, or nil when off.
        var cap: (width: Int, height: Int)? {
            switch self {
            case .off: return nil
            case .upTo1440p: return (2560, 1440)
            case .upTo4K: return (3840, 2160)
            }
        }
    }

    /// The console's range for a bitrate set by hand (PXPlay's).
    static let bitrateRangeMbps = 2...100
    /// The console's own 1080p preset.
    static let presetBitrateMbps = 15

    var height: Int = 1080 { didSet { save(height, "height") } }
    var fps: Int = 60 { didSet { save(fps, "fps") } }
    var bitrateAuto: Bool = true { didSet { save(bitrateAuto, "bitrateAuto") } }
    var bitrateMbps: Int = 40 {
        didSet {
            let clamped = min(Self.bitrateRangeMbps.upperBound, max(Self.bitrateRangeMbps.lowerBound, bitrateMbps))
            if clamped != bitrateMbps { bitrateMbps = clamped; return }
            save(bitrateMbps, "bitrateMbps")
        }
    }
    var hdr: Bool = false { didSet { save(hdr, "hdr") } }
    var hevc: Bool = true { didSet { save(hevc, "hevc") } }
    var presentation: Presentation = .lowestLatency { didSet { save(presentation.rawValue, "presentation") } }
    var upscaling: Upscaling = .off { didSet { save(upscaling.rawValue, "upscaling") } }
    var haptics: HapticsMode = .actuators { didSet { save(haptics.rawValue, "haptics") } }
    var adaptiveTriggers: Bool = true { didSet { save(adaptiveTriggers, "adaptiveTriggers") } }
    var lightBar: Bool = true { didSet { save(lightBar, "lightBar") } }
    var gameModeBoost: Bool = true { didSet { save(gameModeBoost, "gameModeBoost") } }
    var restWhenStreamEnds: Bool = false { didSet { save(restWhenStreamEnds, "restWhenStreamEnds") } }

    @ObservationIgnored private var loading = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loading = true
        defer { loading = false }
        if let v = defaults.object(forKey: Self.key("height")) as? Int { height = v == 720 ? 720 : 1080 }
        if let v = defaults.object(forKey: Self.key("fps")) as? Int { fps = v == 30 ? 30 : 60 }
        if let v = defaults.object(forKey: Self.key("bitrateAuto")) as? Bool { bitrateAuto = v }
        if let v = defaults.object(forKey: Self.key("bitrateMbps")) as? Int { bitrateMbps = v }
        if let v = defaults.object(forKey: Self.key("hdr")) as? Bool { hdr = v }
        if let v = defaults.object(forKey: Self.key("hevc")) as? Bool { hevc = v }
        if let v = defaults.string(forKey: Self.key("presentation")).flatMap(Presentation.init) { presentation = v }
        if let v = defaults.string(forKey: Self.key("haptics")).flatMap(HapticsMode.init) { haptics = v }
        if let v = defaults.string(forKey: Self.key("upscaling")).flatMap(Upscaling.init) { upscaling = v }
        if let v = defaults.object(forKey: Self.key("adaptiveTriggers")) as? Bool { adaptiveTriggers = v }
        if let v = defaults.object(forKey: Self.key("lightBar")) as? Bool { lightBar = v }
        if let v = defaults.object(forKey: Self.key("gameModeBoost")) as? Bool { gameModeBoost = v }
        if let v = defaults.object(forKey: Self.key("restWhenStreamEnds")) as? Bool { restWhenStreamEnds = v }
    }

    static func key(_ name: String) -> String { "PS5.\(name)" }

    private func save(_ value: Any, _ name: String) {
        guard !loading else { return }
        defaults.set(value, forKey: Self.key(name))
    }

    /// What a session needs, read once at connect (the backend runs off the
    /// main actor).
    var snapshot: Snapshot {
        Snapshot(height: height, fps: fps, bitrateKbps: bitrateAuto ? nil : bitrateMbps * 1000, hdr: hdr,
                 hevc: hevc, presentsDirect: presentation == .lowestLatency, upscaling: upscaling, haptics: haptics,
                 adaptiveTriggers: adaptiveTriggers, lightBar: lightBar, gameModeBoost: gameModeBoost,
                 restWhenStreamEnds: restWhenStreamEnds)
    }

    struct Snapshot: Sendable, Equatable {
        var height = 1080
        var fps = 60
        /// nil: the console's preset, and it adapts.
        var bitrateKbps: Int?
        var hdr = false
        var hevc = true
        var presentsDirect = true
        var upscaling: Upscaling = .off
        var haptics: HapticsMode = .actuators
        var adaptiveTriggers = true
        var lightBar = true
        var gameModeBoost = true
        var restWhenStreamEnds = false
    }
}
