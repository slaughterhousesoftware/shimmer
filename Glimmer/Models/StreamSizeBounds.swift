//
//  StreamSizeBounds.swift
//
//  The pure rules for a stream's size and refresh: the bounds every size
//  field is clamped to, and the refresh cap at the display. Testable without
//  an AppModel, an NSScreen, or a window.
//

import Foundation

/// The refresh a stream asks for. The stream is always a window (full screen
/// is the same window in a Space), so it never asks for more than the display
/// shows - a 60 Hz panel can't show 120, asking would only drop frames.
enum StreamRefresh {
    /// The user's Hz capped at the display's current maximum and floored at
    /// the host's 30 Hz minimum. 0 or a negative display value means unknown
    /// and falls back to 60.
    static func capped(customFPS: Int, displayMaxHz: Int) -> Int {
        let cap = displayMaxHz > 0 ? displayMaxHz : fallbackDisplayMaxHz
        return max(StreamSizeBounds.fps.lowerBound, min(StreamSizeBounds.clampFPS(customFPS), cap))
    }

    /// The refresh assumed when the display can't report one (a headless or
    /// mid-reconfigure NSScreen answers 0).
    static let fallbackDisplayMaxHz = 60
}

/// The bounds every stream-size field is clamped to, shared by the Custom
/// preset's fields and the init-time heal of persisted values. 640x480 is the
/// smallest mode a host will encode; 8K / 240 Hz are Moonlight's upstream
/// ceilings. One home so the sites can't drift.
enum StreamSizeBounds {
    static let width = 640...7680
    static let height = 480...4320
    static let fps = 30...240

    static func clampWidth(_ value: Int) -> Int { min(max(value, width.lowerBound), width.upperBound) }
    static func clampHeight(_ value: Int) -> Int { min(max(value, height.lowerBound), height.upperBound) }
    static func clampFPS(_ value: Int) -> Int { min(max(value, fps.lowerBound), fps.upperBound) }
}
