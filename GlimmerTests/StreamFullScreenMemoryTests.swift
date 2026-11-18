//
//  StreamFullScreenMemoryTests.swift
//
//  Every stream opens as a window; it goes full screen on its own only when
//  the user left the last one full screen. These pin what counts as the
//  user's choice, and how the old "Show the stream" setting carries over.
//

import AppKit
import Foundation
import Testing
@testable import Glimmer

struct StreamFullScreenMemoryTests {

    private func freshDefaults() -> UserDefaults {
        let name = "StreamFullScreenMemoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aFreshInstallOpensFullScreen() {
        #expect(StreamFullScreenMemory.opensFullScreen(freshDefaults()))
    }

    @Test func theOldSettingCarriesOver() {
        let window = freshDefaults()
        window.set("window", forKey: "streamDisplayMode")
        #expect(!StreamFullScreenMemory.opensFullScreen(window))
        let fullScreen = freshDefaults()
        fullScreen.set("fullScreen", forKey: "streamDisplayMode")
        #expect(StreamFullScreenMemory.opensFullScreen(fullScreen))
    }

    @Test func whatTheUserLastDidWins() {
        let defaults = freshDefaults()
        defaults.set("fullScreen", forKey: "streamDisplayMode")
        StreamFullScreenMemory.remember(false, defaults)
        #expect(!StreamFullScreenMemory.opensFullScreen(defaults))
        StreamFullScreenMemory.remember(true, defaults)
        #expect(StreamFullScreenMemory.opensFullScreen(defaults))
    }

    /// Ending the stream, and Shimmer's own trips out of full screen (for
    /// Picture in Picture and back), are not the user choosing a window.
    @Test func onlyTheUsersOwnChangesAreRemembered() {
        #expect(StreamFullScreenMemory.shouldRemember(closing: false, ours: false))
        #expect(!StreamFullScreenMemory.shouldRemember(closing: true, ours: false))
        #expect(!StreamFullScreenMemory.shouldRemember(closing: false, ours: true))
    }
}

/// ⌃⌘F (and Globe-F) is the Mac's full-screen key: in the stream it toggles
/// the window, even with the pointer grabbed, and never reaches the PC.
struct FullScreenChordTests {
    @Test func controlCommandFAndGlobeF() {
        #expect(InputForwarder.isFullScreenChord(characters: "f", modifiers: [.control, .command]))
        #expect(InputForwarder.isFullScreenChord(characters: "F", modifiers: [.control, .command]))
        #expect(InputForwarder.isFullScreenChord(characters: "f", modifiers: [.function]))
    }

    @Test func nothingElse() {
        #expect(!InputForwarder.isFullScreenChord(characters: "f", modifiers: []))
        #expect(!InputForwarder.isFullScreenChord(characters: "f", modifiers: [.command]))
        #expect(!InputForwarder.isFullScreenChord(characters: "f", modifiers: [.control]))
        #expect(!InputForwarder.isFullScreenChord(characters: "f", modifiers: [.control, .command, .shift]))
        #expect(!InputForwarder.isFullScreenChord(characters: "g", modifiers: [.control, .command]))
        #expect(!InputForwarder.isFullScreenChord(characters: nil, modifiers: [.control, .command]))
    }
}
