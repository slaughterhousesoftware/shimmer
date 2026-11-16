//
//  HostSystemKindTests.swift
//
//  Which system a machine runs, for its logo: PlayStation, Windows (TTL 128),
//  Mac (by name), else Linux.
//

import Testing
@testable import Glimmer

struct HostSystemKindTests {
    @Test func ps5IsPlayStation() {
        #expect(HostSystemKind.resolve(isPlayStation: true, ttl: 128, serverName: "windows-pc") == .playStation)
    }
    @Test func ttl128IsWindows() {
        #expect(HostSystemKind.resolve(isPlayStation: false, ttl: 128, serverName: "gaming") == .windows)
    }
    @Test func ttl64IsLinux() {
        #expect(HostSystemKind.resolve(isPlayStation: false, ttl: 64, serverName: "bazzite") == .linux)
    }
    @Test func macNameIsMac() {
        #expect(HostSystemKind.resolve(isPlayStation: false, ttl: 64, serverName: "Kevins-MacBook-Pro") == .mac)
    }
    @Test func unreachableHostIsLinux() {
        #expect(HostSystemKind.resolve(isPlayStation: false, ttl: nil, serverName: "bazzite") == .linux)
    }
    @Test func windowsNameWithoutTTLIsWindows() {
        #expect(HostSystemKind.resolve(isPlayStation: false, ttl: nil, serverName: "DESKTOP-WIN11") == .windows)
    }
    @Test func parsesPingTTL() {
        #expect(HostSystemKind.ttl(fromPingOutput: "64 bytes from 192.168.50.40: icmp_seq=0 ttl=64 time=2.8 ms") == 64)
        #expect(HostSystemKind.ttl(fromPingOutput: "Request timeout for icmp_seq 0") == nil)
    }
}
