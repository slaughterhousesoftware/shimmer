//
//  PlayStationSettings.swift
//
//  The PS5's own stream settings, apart from the Sunshine ones: a PS5 stream
//  is a different kind of stream (fixed 720p/1080p presets, 30/60 fps, its
//  own bitrate range), so it gets its own settings instead of borrowing
//  numbers meant for a PC. The pad's haptics, triggers and light bar are
//  shared with PC streams (ControllerSettings). Each console
//  has its own (`forConsole`), persisted under "PS5.<host id>." keys; the
//  bare "PS5." keys are the pre-per-console values, copied once to every
//  console registered then (`migrateGlobalToConsoles`).
//

import Foundation
import Observation

@MainActor
@Observable
final class PlayStationSettings {

    /// One console's settings - the same instance every time, so the
    /// settings page and the stream it starts agree.
    /// The console users who play as players 2-4 when more controllers join,
    /// as base64 PSN account IDs (8 bytes, little-endian - the form Remote
    /// Play registration uses) in `PS5.extraPlayers`. Each must already be a
    /// user on the console.
    nonisolated static var extraPlayerAccounts: [UInt64] {
        (UserDefaults.standard.stringArray(forKey: "PS5.extraPlayers") ?? []).compactMap(accountID(base64:))
    }

    nonisolated static func accountID(base64: String) -> UInt64? {
        guard let data = Data(base64Encoded: base64), data.count == 8 else { return nil }
        return data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    static func forConsole(_ hostID: String) -> PlayStationSettings {
        if let known = byConsole[hostID] { return known }
        let made = PlayStationSettings(hostID: hostID)
        byConsole[hostID] = made
        return made
    }
    private static var byConsole: [String: PlayStationSettings] = [:]

    static let settingNames = ["height", "fps", "bitrateAuto", "bitrateMbps", "hdr", "hevc", "presentation",
                               "restWhenStreamEnds"]

    /// Once: consoles registered before per-console settings keep what they
    /// had (the bare "PS5." values). A console registered later starts from
    /// the defaults.
    static func migrateGlobalToConsoles(_ hostIDs: [String], defaults: UserDefaults = .standard) {
        let flag = "PS5.perConsoleMigrated"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        for id in hostIDs {
            for name in settingNames {
                let consoleKey = key(name, hostID: id)
                if defaults.object(forKey: consoleKey) == nil, let value = defaults.object(forKey: key(name)) {
                    defaults.set(value, forKey: consoleKey)
                }
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

    /// The console's range for a bitrate set by hand (PXPlay's).
    static let bitrateRangeMbps = 2...100
    /// The console's own 1080p preset.
    /// Automatic at 1080p: what the PS Portal - Sony's own Remote Play
    /// handheld - asks for (25 Mbps), not the console's 15 Mbps preset that
    /// libchiaki and Sony's Mac app leave it on. Still not held: the console
    /// may lower it when the network struggles.
    static let presetBitrateMbps = 25

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
    var restWhenStreamEnds: Bool = false { didSet { save(restWhenStreamEnds, "restWhenStreamEnds") } }

    @ObservationIgnored private var loading = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let hostID: String?
    /// Vibration, adaptive triggers and the light bar: one set for every
    /// machine, on the Controller tab.
    @ObservationIgnored private let controller: ControllerSettings

    /// `hostID` nil: the bare pre-per-console keys.
    init(hostID: String? = nil, defaults: UserDefaults = .standard, controller: ControllerSettings? = nil) {
        self.defaults = defaults
        self.hostID = hostID
        self.controller = controller ?? .shared
        loading = true
        defer { loading = false }
        if let v = defaults.object(forKey: Self.key(hostID: hostID, "height")) as? Int { height = v == 720 ? 720 : 1080 }
        if let v = defaults.object(forKey: Self.key(hostID: hostID, "fps")) as? Int { fps = v == 30 ? 30 : 60 }
        if let v = defaults.object(forKey: Self.key(hostID: hostID, "bitrateAuto")) as? Bool { bitrateAuto = v }
        if let v = defaults.object(forKey: Self.key(hostID: hostID, "bitrateMbps")) as? Int { bitrateMbps = v }
        if let v = defaults.object(forKey: Self.key(hostID: hostID, "hdr")) as? Bool { hdr = v }
        if let v = defaults.object(forKey: Self.key(hostID: hostID, "hevc")) as? Bool { hevc = v }
        if let v = defaults.string(forKey: Self.key(hostID: hostID, "presentation")).flatMap(Presentation.init) { presentation = v }
        if let v = defaults.object(forKey: Self.key(hostID: hostID, "restWhenStreamEnds")) as? Bool { restWhenStreamEnds = v }
    }

    static func key(_ name: String, hostID: String? = nil) -> String {
        hostID.map { "PS5.\($0).\(name)" } ?? "PS5.\(name)"
    }
    static func key(hostID: String?, _ name: String) -> String { key(name, hostID: hostID) }

    private func save(_ value: Any, _ name: String) {
        guard !loading else { return }
        defaults.set(value, forKey: Self.key(name, hostID: hostID))
    }

    /// What a session needs, read once at connect (the backend runs off the
    /// main actor).
    var snapshot: Snapshot {
        Snapshot(height: height, fps: fps, bitrateKbps: bitrateAuto ? nil : bitrateMbps * 1000, hdr: hdr,
                 hevc: hevc, presentsDirect: presentation == .lowestLatency, controller: controller.snapshot,
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
        /// The Controller tab's settings, shared with PC streams.
        var controller = ControllerSettings.Snapshot()
        var restWhenStreamEnds = false
    }
}
