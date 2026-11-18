//
//  StreamFullScreenMemory.swift
//
//  Every stream opens as an ordinary window. The green button (or ⌃⌘F) takes
//  it into macOS full screen, and the next stream opens the way the user left
//  the last one. This is the one remembered bit, and the rule for when it is
//  the user's choice.
//

import Foundation

enum StreamFullScreenMemory {
    static let defaultsKey = "streamOpensFullScreen"

    /// The old "Show the stream" setting's key: until the user has gone in or
    /// out of full screen once, their old choice decides ("window" opened a
    /// window; anything else, or nothing, was full screen).
    static let legacyDisplayModeKey = "streamDisplayMode"

    static func opensFullScreen(_ defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: defaultsKey) != nil { return defaults.bool(forKey: defaultsKey) }
        return defaults.string(forKey: legacyDisplayModeKey) != "window"
    }

    static func remember(_ fullScreen: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(fullScreen, forKey: defaultsKey)
    }

    /// A full-screen change is the user's choice unless the stream is ending
    /// (closing leaves full screen on its way out) or Shimmer made it itself
    /// (leaving full screen for Picture in Picture, going back after).
    static func shouldRemember(closing: Bool, ours: Bool) -> Bool {
        !closing && !ours
    }
}
