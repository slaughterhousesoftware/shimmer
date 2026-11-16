//
//  HostAvatarTests.swift
//
//  A machine's round avatar: the distro its name gives (Bazzite's own
//  artwork), else its detected system; a PS5 is always PlayStation.
//

import Testing
@testable import Glimmer

struct HostAvatarTests {
    @Test func ps5IsPlayStation() {
        #expect(HostAvatar.mark(isPlayStation: true, serverName: "PS5-661", kind: .playStation) == .playStation)
    }
    @Test func distroNameWins() {
        #expect(HostAvatar.mark(isPlayStation: false, serverName: "bazzite", kind: .linux) == .icon(.bazzite))
    }
    @Test func unknownNameFallsBackToDetectedSystem() {
        #expect(HostAvatar.mark(isPlayStation: false, serverName: "DESKTOP-ABC123", kind: .windows) == .icon(.windows))
        #expect(HostAvatar.mark(isPlayStation: false, serverName: "gaming", kind: .linux) == .icon(.linux))
        #expect(HostAvatar.mark(isPlayStation: false, serverName: "studio", kind: .mac) == .icon(.macOS))
    }
}
