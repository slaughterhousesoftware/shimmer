//
//  ControllerSettings.swift
//
//  The controller's settings, one set for every machine: what a PS5 stream
//  and a PC stream let the game do to the pad - vibrate it, stiffen its
//  triggers, colour its light bar. Shown on Settings' Controller tab.
//  Before this, each PS5 had its own (under "PS5.<host id>."), and a PC
//  stream always allowed all three; a registered console's choices move
//  here once, at launch (`migrateFromConsoles`).
//

import Foundation
import Observation

@MainActor
@Observable
final class ControllerSettings {
    static var shared: ControllerSettings {
        if let made = sharedIfMade { return made }
        let made = ControllerSettings()
        sharedIfMade = made
        return made
    }
    private static var sharedIfMade: ControllerSettings?

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
        reload()
    }

    /// Re-reads the saved settings (after `migrateFromConsoles` moved some).
    func reload() {
        loading = true
        defer { loading = false }
        let snapshot = Snapshot.load(defaults)
        vibration = snapshot.vibration
        adaptiveTriggers = snapshot.adaptiveTriggers
        lightBar = snapshot.lightBar
    }

    /// Once: the PS5 choices from before these were shared become these.
    /// Each setting not already chosen here takes the first registered
    /// console's (`consoleIDs`, in order) that has one, else the shared
    /// value from before per-console settings ("PS5.<name>"). A console
    /// that's no longer registered doesn't count. `reloading`: instances to
    /// refresh (default: the shared one, if made).
    static func migrateFromConsoles(_ consoleIDs: [String], defaults: UserDefaults = .standard,
                                    reloading: [ControllerSettings]? = nil) {
        let flag = Snapshot.key("migratedFromConsoles")
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        let moves: [(name: String, ps5Name: String, valid: (Any) -> Bool)] = [
            ("vibration", "haptics", { ($0 as? String).flatMap(Vibration.init) != nil }),
            ("adaptiveTriggers", "adaptiveTriggers", { $0 is Bool }),
            ("lightBar", "lightBar", { $0 is Bool }),
        ]
        for move in moves where defaults.object(forKey: Snapshot.key(move.name)) == nil {
            let keys = consoleIDs.map { "PS5.\($0).\(move.ps5Name)" } + ["PS5.\(move.ps5Name)"]
            if let value = keys.lazy.compactMap({ defaults.object(forKey: $0) }).first(where: move.valid) {
                defaults.set(value, forKey: Snapshot.key(move.name))
            }
        }
        for settings in reloading ?? [sharedIfMade].compactMap({ $0 }) { settings.reload() }
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

        /// Reads the saved settings (the defaults for any never saved).
        static func load(_ defaults: UserDefaults) -> Snapshot {
            var snapshot = Snapshot()
            if let v = defaults.string(forKey: key("vibration")).flatMap(Vibration.init) { snapshot.vibration = v }
            if let v = defaults.object(forKey: key("adaptiveTriggers")) as? Bool { snapshot.adaptiveTriggers = v }
            if let v = defaults.object(forKey: key("lightBar")) as? Bool { snapshot.lightBar = v }
            return snapshot
        }
    }
}
