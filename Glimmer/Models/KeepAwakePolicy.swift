//
//  KeepAwakePolicy.swift
//
//  Whether a live stream keeps the Mac and its display from sleeping. A game
//  stream is video the user is watching, but to the OS there is no local
//  input - a controller doesn't reset the idle timer - so without an
//  assertion the screen dims and sleeps minutes into a pad-only session.
//  That was always on, then a toggle in General; the toggle is gone and a
//  fresh install is off (the Mac's own sleep rules apply). On holds the
//  assertion for the whole session, off never holds it. A three-way "only
//  while the window is showing" middle state existed briefly and was dropped.
//

import Foundation

public enum KeepAwakePolicy: String, CaseIterable, Identifiable, Sendable {
    /// Hold the assertion for the whole session - every build before this one.
    case always
    /// Never hold it; the Mac sleeps exactly as it would without a stream.
    case never

    public var id: String { rawValue }

    /// A fresh install lets the Mac sleep as it normally would.
    public static let defaultPolicy: KeepAwakePolicy = .never

    /// UserDefaults key. Registered (never written) with `defaultPolicy` in
    /// GlimmerApp so the raw read agrees with the declared default.
    public static let defaultsKey = "keepAwakePolicy"

    public var displayName: String {
        switch self {
        case .always: return "Always"
        case .never: return "Never"
        }
    }

    /// Resolve a persisted raw value. Absent or unrecognised lands on the
    /// default rather than guessing. The retired "whileShowing" kept the Mac
    /// awake while playing, so it reads as on.
    public static func persisted(rawValue: String?) -> KeepAwakePolicy {
        if rawValue == "whileShowing" { return .always }
        return rawValue.flatMap(KeepAwakePolicy.init(rawValue:)) ?? defaultPolicy
    }

    /// Whether the sleep assertion is held right now. `windowShowing` is kept
    /// so the session's reconcile (which runs on the window's shown / hidden
    /// edge) needs no change; no current policy depends on it.
    public func holdsSleepAssertion(windowShowing: Bool) -> Bool {
        switch self {
        case .always: return true
        case .never: return false
        }
    }

}
