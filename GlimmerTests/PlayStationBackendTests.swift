//
//  PlayStationBackendTests.swift
//
//  The pure parts of the PS5 engine: GameStream → DualSense button mapping,
//  the Y-axis flip, parameter-set splitting, the wake credential, and the
//  console store round trip.
//

import Foundation
import Testing

@testable import Glimmer

struct PlayStationBackendTests {

    @Test func faceButtonsUseXboxPositions() {
        let b = PlayStationBackend.chiakiButtons(fromGameStream:
            StreamProtocol.A_FLAG | StreamProtocol.B_FLAG | StreamProtocol.X_FLAG | StreamProtocol.Y_FLAG)
        #expect(b == CHIAKI_CONTROLLER_BUTTON_CROSS.rawValue | CHIAKI_CONTROLLER_BUTTON_MOON.rawValue
            | CHIAKI_CONTROLLER_BUTTON_BOX.rawValue | CHIAKI_CONTROLLER_BUTTON_PYRAMID.rawValue)
    }

    @Test func systemButtons() {
        #expect(PlayStationBackend.chiakiButtons(fromGameStream: StreamProtocol.SPECIAL_FLAG)
            == CHIAKI_CONTROLLER_BUTTON_PS.rawValue)
        #expect(PlayStationBackend.chiakiButtons(fromGameStream: StreamProtocol.PLAY_FLAG)
            == CHIAKI_CONTROLLER_BUTTON_OPTIONS.rawValue)
        #expect(PlayStationBackend.chiakiButtons(fromGameStream: StreamProtocol.BACK_FLAG)
            == CHIAKI_CONTROLLER_BUTTON_SHARE.rawValue)
        #expect(PlayStationBackend.chiakiButtons(fromGameStream: StreamProtocol.TOUCHPAD_FLAG)
            == CHIAKI_CONTROLLER_BUTTON_TOUCHPAD.rawValue)
        #expect(PlayStationBackend.chiakiButtons(fromGameStream: 0) == 0)
    }

    @Test func dpadAndShoulders() {
        let b = PlayStationBackend.chiakiButtons(fromGameStream:
            StreamProtocol.DOWN_FLAG | StreamProtocol.LB_FLAG | StreamProtocol.RS_CLK_FLAG)
        #expect(b == CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN.rawValue | CHIAKI_CONTROLLER_BUTTON_L1.rawValue
            | CHIAKI_CONTROLLER_BUTTON_R3.rawValue)
    }

    @Test func stickYIsFlippedWithoutOverflow() {
        #expect(PlayStationBackend.flipY(1000) == -1000)
        #expect(PlayStationBackend.flipY(-32768) == 32767)
        #expect(PlayStationBackend.flipY(0) == 0)
    }

    @Test func hevcParameterSetsSplitOutOfAnIDR() {
        // VPS(32) SPS(33) PPS(34) then an IDR slice (19), mixed start-code lengths.
        let au = Data([0, 0, 0, 1, 0x40, 0x01, 0xAA,
                       0, 0, 0, 1, 0x42, 0x01, 0xBB,
                       0, 0, 1, 0x44, 0x01, 0xCC,
                       0, 0, 0, 1, 0x26, 0x01, 0xDD, 0xEE])
        let buffers = PlayStationBackend.splitParameterSets(au, hevc: true)
        #expect(buffers.map(\.kind) == [.vps, .sps, .pps, .picData])
        #expect(buffers[0].data == Data([0, 0, 0, 1, 0x40, 0x01, 0xAA]))
        #expect(buffers[2].data == Data([0, 0, 1, 0x44, 0x01, 0xCC]))
        #expect(buffers[3].data == Data([0, 0, 0, 1, 0x26, 0x01, 0xDD, 0xEE]))
    }

    @Test func headersOnlyFrameLeavesEmptyPicture() {
        // What the console sends first: parameter sets with no picture. The
        // backend holds these for the next frame instead of decoding them.
        let au = Data([0, 0, 0, 1, 0x40, 0x01, 0xAA, 0, 0, 0, 1, 0x42, 0x01, 0xBB, 0, 0, 0, 1, 0x44, 0x01, 0xCC])
        let buffers = PlayStationBackend.splitParameterSets(au, hevc: true)
        #expect(buffers.last?.kind == .picData)
        #expect(buffers.last?.data.isEmpty == true)
    }

    @Test func h264ParameterSets() {
        let au = Data([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 0, 1, 0x68, 0xBB, 0, 0, 0, 1, 0x65, 0xCC])
        let buffers = PlayStationBackend.splitParameterSets(au, hevc: false)
        #expect(buffers.map(\.kind) == [.sps, .pps, .picData])
    }

    @Test func wakeCredentialReadsRegistKeyAsHex() {
        var key = Data("1a2b3c4d".utf8)
        key.append(Data(repeating: 0, count: 8))
        let console = PlayStationConsole(id: "aabbccddeeff", nickname: "PS5", address: "10.0.0.2",
                                         registKey: key, rpKey: Data(count: 16), target: 1_000_100)
        #expect(console.wakeCredential == 0x1a2b3c4d)
        #expect(console.hostID == "ps5-aabbccddeeff")
    }

    @MainActor
    @Test func storeRoundTripsAndIsPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlayStationStore(directory: dir)
        let console = PlayStationConsole(id: "aabbccddeeff", nickname: "PS5", address: "10.0.0.2",
                                         registKey: Data(repeating: 1, count: 16),
                                         rpKey: Data(repeating: 2, count: 16), target: 1_000_100)
        store.upsert(console)
        store.updateAddress(id: console.id, address: "10.0.0.3")

        let reloaded = PlayStationStore(directory: dir)
        #expect(reloaded.consoles.count == 1)
        #expect(reloaded.consoles.first?.address == "10.0.0.3")
        #expect(reloaded.consoles.first?.rpKey == console.rpKey)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("consoles.json").path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        reloaded.remove(id: console.id)
        #expect(PlayStationStore(directory: dir).consoles.isEmpty)
    }

    @Test func registrationReplyBecomesAConsole() {
        var host = ChiakiRegisteredHost()
        host.target = CHIAKI_TARGET_PS5_1
        withUnsafeMutableBytes(of: &host.server_mac) { $0.copyBytes(from: [0xAA, 0xBB, 0xCC, 0x0D, 0x0E, 0x0F]) }
        withUnsafeMutableBytes(of: &host.server_nickname) { $0.copyBytes(from: Array("PS5-123".utf8)) }
        let registKey = Array("0a1b2c3d".utf8) + [UInt8](repeating: 0, count: 8)
        withUnsafeMutableBytes(of: &host.rp_regist_key) { $0.copyBytes(from: registKey) }
        withUnsafeMutableBytes(of: &host.rp_key) { $0.copyBytes(from: [UInt8](1...16)) }

        let console = PlayStationRegistration.console(from: host, address: "10.0.0.9", accountID: "AQIDBAUGBwg=")
        #expect(console.id == "aabbcc0d0e0f")
        #expect(console.hostID == "ps5-aabbcc0d0e0f")
        #expect(console.nickname == "PS5-123")
        #expect(console.address == "10.0.0.9")
        #expect(console.registKey == Data(registKey))
        #expect(console.rpKey == Data([UInt8](1...16)))
        #expect(console.target == Int32(CHIAKI_TARGET_PS5_1.rawValue))
        #expect(console.accountID == "AQIDBAUGBwg=")
        #expect(console.wakeCredential == 0x0a1b2c3d)
    }

    @Test func registrationReplyWithoutNicknameIsNamedPS5() {
        let console = PlayStationRegistration.console(from: ChiakiRegisteredHost(), address: "10.0.0.9", accountID: "x")
        #expect(console.nickname == "PS5")
        #expect(console.id == "000000000000")
    }

    @Test func hapticsWindowBecomesRumble() {
        // Silence and hiss stay off.
        #expect(PlayStationBackend.rumbleStrength(sumLeft: 0, sumRight: 0, frames: 3) == (0, 0))
        #expect(PlayStationBackend.rumbleStrength(sumLeft: 300, sumRight: 0, frames: 3) == (0, 0))
        // Mean |amplitude| per frame, doubled.
        #expect(PlayStationBackend.rumbleStrength(sumLeft: 30_000, sumRight: 3_000, frames: 3) == (20_000, 2_000))
        // Faint but real signal is lifted to the pads' minimum.
        #expect(PlayStationBackend.rumbleStrength(sumLeft: 600, sumRight: 0, frames: 3).0 == 1 << 9)
        // Loud signal saturates.
        #expect(PlayStationBackend.rumbleStrength(sumLeft: 300_000, sumRight: 0, frames: 3).0 == UInt16.max)
        #expect(PlayStationBackend.rumbleStrength(sumLeft: 1, sumRight: 1, frames: 0) == (0, 0))
    }

    @Test func keyboardDrivesAPad() {
        // W + D: up-right on the left stick (Y-down), Return = Cross, Z = full L2.
        let pad = PlayStationBackend.keyboardPad(held: [0x57, 0x44, 0x0D, 0x5A])
        #expect(pad.left_x == Int16.max)
        #expect(pad.left_y == -Int16.max)
        #expect(pad.right_x == 0)
        #expect(pad.l2_state == 255)
        #expect(pad.buttons & CHIAKI_CONTROLLER_BUTTON_CROSS.rawValue != 0)
        #expect(pad.buttons & CHIAKI_CONTROLLER_ANALOG_BUTTON_L2.rawValue != 0)
        // Opposite keys cancel; nothing held is an idle pad.
        #expect(PlayStationBackend.keyboardPad(held: [0x41, 0x44]).left_x == 0)
        #expect(PlayStationBackend.keyboardPad(held: []).buttons == 0)
        #expect(PlayStationBackend.keyboardPad(held: [0x48]).buttons == CHIAKI_CONTROLLER_BUTTON_PS.rawValue)
        #expect(PlayStationBackend.keyboardKeys.contains(0x26))
        #expect(!PlayStationBackend.keyboardKeys.contains(0x58))   // X isn't mapped
    }
}
