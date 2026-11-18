//
//  ControllerSettings.swift
//
//  The controller's settings, one set for every machine: what a PS5 stream
//  and a PC stream let the game do to the pad - vibrate it, stiffen its
//  triggers, colour its light bar. Shown on Settings' Controller tab.
//  Before this, each PS5 had its own (under "PS5.<host id>."), and a PC
//  stream always allowed all three; a console's choices carry over the
//  first time these are read.
//

import Foundation
import Observation

@MainActor
@Observable
final class ControllerSettings {
    static let shared = ControllerSettings()

    enum Vibration: String, CaseIterable, Identifiable, Sendable {
        /// A PS5's haptics on the DualSense's actuators; a PC's rumble.
        case actuators
        /// Plain rumble.
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

    var vibration: Vibration = .actuators { didSet { save(vibration.rawValue, "vibration") } }
    var adaptiveTriggers: Bool = true { didSet { save(adaptiveTriggers, "adaptiveTriggers") } }
    var lightBar: Bool = true { didSet { save(lightBar, "lightBar") } }

    @ObservationIgnored private var loading = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loading = true
        defer { loading = false }
        let snapshot = Snapshot.load(defaults)
        vibration = snapshot.vibration
        adaptiveTriggers = snapshot.adaptiveTriggers
        lightBar = snapshot.lightBar
    }

    var snapshot: Snapshot {
        Snapshot(vibration: vibration, adaptiveTriggers: adaptiveTriggers, lightBar: lightBar)
    }

    private func save(_ value: Any, _ name: String) {
        guard !loading else { return }
        defaults.set(value, forKey: Snapshot.key(name))
    }

    /// The settings as a stream reads them, from any thread.
    struct Snapshot: Sendable, Equatable {
        var vibration: Vibration = .actuators
        var adaptiveTriggers = true
        var lightBar = true

        /// Whether the game may rumble the pad (a PC's motors or trigger
        /// rumble); the PS5's haptics read `vibration` itself.
        var rumble: Bool { vibration != .off }

        static func key(_ name: String) -> String { "Controller.\(name)" }

        /// Reads the saved settings. A setting never saved here yet takes a
        /// PS5's earlier choice: a console's own ("PS5.<id>.<name>", the
        /// first console by id), else the shared one from before per-console
        /// settings ("PS5.<name>").
        static func load(_ defaults: UserDefaults) -> Snapshot {
            var snapshot = Snapshot()
            if let v = value(defaults, "vibration", ps5Name: "haptics").flatMap({ $0 as? String })
                .flatMap(Vibration.init) { snapshot.vibration = v }
            if let v = value(defaults, "adaptiveTriggers", ps5Name: "adaptiveTriggers") as? Bool {
                snapshot.adaptiveTriggers = v
            }
            if let v = value(defaults, "lightBar", ps5Name: "lightBar") as? Bool { snapshot.lightBar = v }
            return snapshot
        }

        private static func value(_ defaults: UserDefaults, _ name: String, ps5Name: String) -> Any? {
            if let own = defaults.object(forKey: key(name)) { return own }
            let suffix = "." + ps5Name
            let console = defaults.dictionaryRepresentation().keys
                .filter { $0.hasPrefix("PS5.") && $0.hasSuffix(suffix) && $0 != "PS5" + suffix }
                .sorted()
                .first
            return console.flatMap { defaults.object(forKey: $0) } ?? defaults.object(forKey: "PS5" + suffix)
        }
    }
}
