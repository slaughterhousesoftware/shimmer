//
//  HostStreamSettings.swift
//
//  One PC's stream settings: what its page on the Servers tab shows and what
//  its streams ask for. Stored per host (JSON in UserDefaults). AppModel keeps
//  the selected PC's copy in its live properties - the quality calculator
//  reads those - and saves every edit back here (AppModel+HostStreamSettings).
//

import Foundation

struct HostStreamSettings: Codable, Equatable, Sendable {
    var qualityPreset: String
    var customWidth: Int
    var customHeight: Int
    var customFPS: Int
    var bitrateAuto: Bool
    var manualBitrateMbps: Int
    var customHDR: Bool
    var quitAppWhenStreamEnds: Bool

    /// A PC added after per-PC settings arrived starts here (AppModel's own
    /// property defaults).
    static let defaults = HostStreamSettings(
        qualityPreset: QualityPreset.defaultPreset.rawValue, customWidth: 1920, customHeight: 1080,
        customFPS: 60, bitrateAuto: true, manualBitrateMbps: 20, customHDR: true,
        quitAppWhenStreamEnds: false)

    /// These settings on a standard size: a Match display, HiDPI or
    /// non-standard Custom size (all gone from the picker) becomes the
    /// standard size nearest what it streamed at. `display` / `hidpi` are
    /// what those two meant on this Mac.
    func withStandardResolution(display: (Int, Int), hidpi: (Int, Int)) -> HostStreamSettings {
        let size: (Int, Int)
        switch QualityPreset(rawValue: qualityPreset) ?? .defaultPreset {
        case .matchDisplay: size = display
        case .hidpi: size = hidpi
        case .custom:
            if CommonResolution.matching(width: customWidth, height: customHeight) != nil { return self }
            size = (customWidth, customHeight)
        }
        let standard = CommonResolution.nearest(width: size.0, height: size.1)
        var fixed = self
        fixed.qualityPreset = QualityPreset.custom.rawValue
        fixed.customWidth = standard.width
        fixed.customHeight = standard.height
        return fixed
    }

    static func storageKey(for hostID: String) -> String { "glimmer.streamSettings.\(hostID)" }

    static func load(hostID: String, defaults: UserDefaults = .standard) -> HostStreamSettings? {
        guard let data = defaults.data(forKey: storageKey(for: hostID)) else { return nil }
        return try? JSONDecoder().decode(HostStreamSettings.self, from: data)
    }

    func save(hostID: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey(for: hostID))
    }

    static func forget(hostID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey(for: hostID))
    }
}
