//
//  TakionV20Tests.swift
//
//  Takion v20, the PS5 stream protocol Sony's app and PXPlay speak
//  (third_party/chiaki-ng-patches/0002, after P5M's mac/TAKION-V20.md): the
//  secp521r1 key exchange, and AV packets with the 8-byte extended header and
//  the reworked audio unit field.
//

import Foundation
import Testing

@testable import Glimmer

struct TakionV20Tests {

    /// The app allocates ChiakiSession itself; the patches change its layout.
    @Test func sessionLayoutMatchesTheLibrary() {
        #expect(MemoryLayout<ChiakiSession>.size == chiaki_shimmer_session_size())
    }

    @Test func p521KeyExchangeAgreesOnA66ByteSecret() {
        let handshakeKey: [UInt8] = [0xfc, 0x5d, 0x4b, 0xa0, 0x3a, 0x35, 0x3a, 0xbb,
                                     0x6a, 0x7f, 0xac, 0x79, 0x1b, 0x17, 0xbb, 0x34]
        var a = ChiakiECDH(), b = ChiakiECDH()
        #expect(chiaki_ecdh_init_p521(&a) == CHIAKI_ERR_SUCCESS)
        #expect(chiaki_ecdh_init_p521(&b) == CHIAKI_ERR_SUCCESS)
        defer { chiaki_ecdh_fini(&a); chiaki_ecdh_fini(&b) }
        #expect(a.secret_size == 66)

        func publicKey(_ e: inout ChiakiECDH) -> (key: [UInt8], sig: [UInt8]) {
            var key = [UInt8](repeating: 0, count: 160), sig = [UInt8](repeating: 0, count: 32)
            var keySize = key.count, sigSize = sig.count
            #expect(chiaki_ecdh_get_local_pub_key(&e, &key, &keySize, handshakeKey, &sig, &sigSize) == CHIAKI_ERR_SUCCESS)
            return (Array(key[..<keySize]), Array(sig[..<sigSize]))
        }
        let pa = publicKey(&a), pb = publicKey(&b)
        #expect(pa.key.count == 133)   // uncompressed: 04 || x || y
        #expect(pa.key.first == 0x04)

        var sa = [UInt8](repeating: 0, count: 66), sb = [UInt8](repeating: 0, count: 66)
        #expect(chiaki_ecdh_derive_secret(&a, &sa, pb.key, pb.key.count, handshakeKey, pb.sig, pb.sig.count) == CHIAKI_ERR_SUCCESS)
        #expect(chiaki_ecdh_derive_secret(&b, &sb, pa.key, pa.key.count, handshakeKey, pa.sig, pa.sig.count) == CHIAKI_ERR_SUCCESS)
        #expect(sa == sb)
        #expect(sa.contains { $0 != 0 })

        // Both ends derive the same stream keys from the 66-byte secret.
        var ga = ChiakiGKCrypt(), gb = ChiakiGKCrypt()
        #expect(chiaki_gkcrypt_init_secret(&ga, nil, 0, 2, handshakeKey, sa, sa.count) == CHIAKI_ERR_SUCCESS)
        #expect(chiaki_gkcrypt_init_secret(&gb, nil, 0, 2, handshakeKey, sb, sb.count) == CHIAKI_ERR_SUCCESS)
        defer { chiaki_gkcrypt_fini(&ga); chiaki_gkcrypt_fini(&gb) }
        var ka = [UInt8](repeating: 0, count: 32), kb = [UInt8](repeating: 0, count: 32)
        #expect(chiaki_gkcrypt_gen_key_stream(&ga, 0, &ka, ka.count) == CHIAKI_ERR_SUCCESS)
        #expect(chiaki_gkcrypt_gen_key_stream(&gb, 0, &kb, kb.count) == CHIAKI_ERR_SUCCESS)
        #expect(ka == kb)
    }

    /// v20 = v12 with 8 bytes after the type byte.
    static func v20(_ v12: [UInt8]) -> [UInt8] {
        [v12[0]] + (0..<8).map { UInt8(0xa0 + $0) } + v12.dropFirst()
    }

    static func parse(_ bytes: [UInt8], v20: Bool) -> (ChiakiErrorCode, ChiakiTakionAVPacket, Int) {
        var buf = bytes
        var packet = ChiakiTakionAVPacket()
        var keys = ChiakiKeyState()
        chiaki_key_state_init(&keys)
        let err = buf.withUnsafeMutableBufferPointer { p in
            v20 ? chiaki_takion_v20_av_packet_parse(&packet, &keys, p.baseAddress, p.count)
                : chiaki_takion_v12_av_packet_parse(&packet, &keys, p.baseAddress, p.count)
        }
        // data offset into the buffer (the pointer dies with buf)
        let offset = buf.withUnsafeMutableBufferPointer { p in
            packet.data.map { $0 - p.baseAddress! } ?? -1
        }
        return (err, packet, offset)
    }

    @Test func videoParsesTheSameAfterTheExtendedHeader() {
        let v12: [UInt8] = [
            0x2, 0x0, 0x2d, 0x0, 0x5, 0x0, 0xc0, 0x1c, 0x1, 0x3, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0,
            0xe4, 0x10, 0x3, 0x67, 0x0, 0x29, 0xf3, 0x2f, 0x98, 0xf6, 0x99, 0x82, 0x83, 0x78, 0xdb, 0x29,
            0x43, 0xa9, 0xe5, 0x88]
        let (ea, a, oa) = Self.parse(v12, v20: false)
        let (eb, b, ob) = Self.parse(Self.v20(v12), v20: true)
        #expect(ea == CHIAKI_ERR_SUCCESS && eb == CHIAKI_ERR_SUCCESS)
        #expect(b.is_video)
        #expect(b.packet_index == a.packet_index && b.frame_index == a.frame_index)
        #expect(b.unit_index == a.unit_index && b.units_in_frame_total == a.units_in_frame_total)
        #expect(b.units_in_frame_fec == a.units_in_frame_fec)
        #expect(b.codec == a.codec && b.key_pos == a.key_pos)
        #expect(ob == oa + 8 && b.data_size == a.data_size)
    }

    /// An audio packet (v12 layout) with this unit field, audio kind byte and payload size.
    static func audioV12(units: UInt32, kind: UInt8, dataSize: Int) -> [UInt8] {
        var p: [UInt8] = [0x03, 0x00, 0x07, 0x00, 0x09]     // type, packet 7, frame 9
        p += withUnsafeBytes(of: units.bigEndian, Array.init)
        p += [0x05] + [0, 0, 0, 0] + [0, 0, 0, 0x40] + [0]  // codec, tag, key_pos, unknown
        p += [kind] + [UInt8](repeating: 0x5a, count: dataSize)
        return p
    }

    /// Mode 2, from a real PS5 packet: units field 0x2002, total 3, 240 bytes =
    /// 1 audio + 2 FEC units of 80 bytes.
    @Test func audioMode2BecomesTheV12UnitLayout() {
        let units: UInt32 = (0 << 24) | (2 << 16) | 0x2002   // index 0, total-1 = 2, mode 2, 2 FEC
        let (err, p, _) = Self.parse(Self.v20(Self.audioV12(units: units, kind: 0x20, dataSize: 240)), v20: true)
        #expect(err == CHIAKI_ERR_SUCCESS)
        #expect(!p.is_video && !p.is_haptics)
        #expect(p.units_in_frame_total == 3)
        var q = p
        #expect(chiaki_takion_av_packet_audio_source_units_count(&q) == 1)
        #expect(chiaki_takion_av_packet_audio_fec_units_count(&q) == 2)
        #expect(chiaki_takion_av_packet_audio_unit_size(&q) == 80)
        #expect(q.data_size == 240)
    }

    /// v20 keeps the haptics marker in the low nibble; the high one means something else.
    @Test func hapticsMarkerIsTheLowNibble() {
        let units: UInt32 = (0 << 24) | (0 << 16) | 0x2000   // one unit, no FEC
        let (e20, h20, _) = Self.parse(Self.v20(Self.audioV12(units: units, kind: 0x22, dataSize: 120)), v20: true)
        #expect(e20 == CHIAKI_ERR_SUCCESS && h20.is_haptics)
        var h = h20
        #expect(chiaki_takion_av_packet_audio_unit_size(&h) == 120)
        let (_, h12, _) = Self.parse(Self.audioV12(units: 0x0000_7801, kind: 0x02, dataSize: 120), v20: false)
        #expect(h12.is_haptics)
        let (_, game, _) = Self.parse(Self.v20(Self.audioV12(units: units, kind: 0x20, dataSize: 120)), v20: true)
        #expect(!game.is_haptics)
    }

    /// Mode 1 (one whole unit per packet) only comes with multichannel audio,
    /// which Shimmer doesn't ask for; it must not be misread as v12.
    @Test func audioMode1IsRefused() {
        let units: UInt32 = (0 << 24) | (2 << 16) | 0x1002
        let (err, _, _) = Self.parse(Self.v20(Self.audioV12(units: units, kind: 0x60, dataSize: 242)), v20: true)
        #expect(err == CHIAKI_ERR_INVALID_DATA)
    }

    @Test func truncatedV20PacketsAreRefused() {
        let (err, _, _) = Self.parse([0x02, 1, 2, 3, 4, 5, 6, 7], v20: true)
        #expect(err == CHIAKI_ERR_BUF_TOO_SMALL)
    }

    // MARK: Feedback history records (chiaki-ng-core cross-check, 2026-11-17)

    /// Formats `events` through a history buffer, the way the feedback sender does.
    private static func history(trailingByte: Bool, _ events: [ChiakiFeedbackHistoryEvent]) -> [UInt8] {
        var buffer = ChiakiFeedbackHistoryBuffer()
        #expect(chiaki_feedback_history_buffer_init(&buffer, 8) == CHIAKI_ERR_SUCCESS)
        defer { chiaki_feedback_history_buffer_fini(&buffer) }
        buffer.button_trailing_byte = trailingByte
        // The buffer formats newest first; push oldest first.
        for var event in events { chiaki_feedback_history_buffer_push(&buffer, &event) }
        var out = [UInt8](repeating: 0xee, count: 64)
        var size = out.count
        #expect(chiaki_feedback_history_buffer_format(&buffer, &out, &size) == CHIAKI_ERR_SUCCESS)
        return Array(out.prefix(size))
    }

    private static func button(_ button: UInt64, _ state: UInt8) -> ChiakiFeedbackHistoryEvent {
        var event = ChiakiFeedbackHistoryEvent()
        #expect(chiaki_feedback_history_event_set_button(&event, button, state) == CHIAKI_ERR_SUCCESS)
        return event
    }

    /// From Takion 19 every button record ends with a byte (0): chiaki-ng-core
    /// (`feedback_button_trailing_byte_version = 19`, its v20 vector for a PS
    /// release is 80 8e 00) and PXPlay's v20 record layout both send it.
    @Test func v20ButtonRecordsEndWithATrailingByte() {
        let ps = UInt64(CHIAKI_CONTROLLER_BUTTON_PS.rawValue)
        #expect(Self.history(trailingByte: true, [Self.button(ps, 0)]) == [0x80, 0x8e, 0x00])
        let l2 = UInt64(CHIAKI_CONTROLLER_ANALOG_BUTTON_L2.rawValue)
        #expect(Self.history(trailingByte: true, [Self.button(l2, 0xff)]) == [0x80, 0x86, 0xff, 0x00])
    }

    /// Before 19 the records are as they were.
    @Test func v12ButtonRecordsHaveNoTrailingByte() {
        let ps = UInt64(CHIAKI_CONTROLLER_BUTTON_PS.rawValue)
        #expect(Self.history(trailingByte: false, [Self.button(ps, 0)]) == [0x80, 0x8e])
    }

    /// Only button records (kind 4) gain the byte: touch records don't, and a
    /// presence record for pad 1 does.
    @Test func v20TrailingByteIsForButtonRecordsOnly() {
        var touch = ChiakiFeedbackHistoryEvent()
        chiaki_feedback_history_event_set_touchpad(&touch, true, 1, 0x123, 0x456)
        var presence = ChiakiFeedbackHistoryEvent()
        chiaki_feedback_history_event_set_presence(&presence, 1, true)
        let ps = UInt64(CHIAKI_CONTROLLER_BUTTON_PS.rawValue)
        #expect(Self.history(trailingByte: true, [touch, presence, Self.button(ps, 0xff)]) == [
            0x80, 0xae, 0x00,           // newest: PS down
            0x81, 0xbf, 0x00,           // pad 1 joined
            0xd0, 0x01, 0x12, 0x34, 0x56 // touch down, no trailing byte
        ])
    }

    /// A motion sample that isn't a number goes out as rest - gravity on Y and
    /// the identity orientation (chiaki-ng-core) - not 0 g and an undefined quaternion.
    @Test func nonFiniteMotionIsSentAsRest() {
        func encoded(_ edit: (inout ChiakiFeedbackState) -> Void) -> [UInt8] {
            var state = ChiakiFeedbackState()
            state.accel_y = 1
            state.orient_w = 1
            edit(&state)
            var buf = [UInt8](repeating: 0, count: 0x1c)
            chiaki_feedback_state_format_v12(&buf, &state)
            return buf
        }
        let rest = encoded { _ in }
        #expect(encoded { $0.accel_x = .nan } == rest)
        #expect(encoded { $0.accel_z = .infinity } == rest)
        #expect(encoded { $0.orient_x = .nan } == rest)
        #expect(encoded { $0.gyro_y = .nan } == rest)
    }

    // MARK: Pad info (a live PS5, Takion 20, 2026-11-17)

    private static func padInfo(_ hex: String) -> ChiakiPadInfo? {
        let bytes = hex.split(separator: " ").map { UInt8($0, radix: 16)! }
        var info = ChiakiPadInfo()
        return chiaki_pad_info_parse(bytes, bytes.count, &info) ? info : nil
    }

    /// At session start: pad 0, a motion reset, intensities 1/1.
    @Test func padInfoForPadZeroAtStart() throws {
        let info = try #require(Self.padInfo("00 01 05 08 00 00 00 00 00 00 00 00 01 00 00 01 00 00 00 01 01 01 00 00 00"))
        #expect(info.index == 0)
        #expect(info.motion_reset)
        #expect(info.user_valid)
        #expect(info.haptic_intensity == 1 && info.trigger_intensity == 1)
    }

    /// When player 2 is seated the console sends pad info for pad 1 (index in
    /// the low nibble of [8]) - blue, with byte [12] set. That is pad 1's, not a
    /// reset of player 1's motion (chiaki-ng-core applies reset to index 0 only).
    @Test func padInfoForPadOneIsNotPlayerOnes() throws {
        let joining = try #require(Self.padInfo("00 3f ea 61 00 00 07 96 01 00 00 ff 01 00 00 00 00 00 00 01 01 01 00 00 00"))
        #expect(joining.index == 1)
        #expect(joining.led.0 == 0 && joining.led.1 == 0 && joining.led.2 == 0xff)
        #expect(!joining.motion_reset)
        #expect(!joining.user_valid)
        let seated = try #require(Self.padInfo("00 42 3a b7 00 00 07 e7 01 00 00 00 00 00 00 03 00 00 00 01 01 01 00 00 00"))
        #expect(seated.index == 1)
        #expect(seated.user_valid)
    }

    /// The 0x11 layout (no 8-byte prefix) reads the same fields from offset 0.
    @Test func padInfoShortLayout() throws {
        let info = try #require(Self.padInfo("01 00 00 ff 01 00 00 03 00 00 00 00 02 03 00 00 00"))
        #expect(info.index == 1 && info.led.2 == 0xff && !info.motion_reset && info.user_valid)
        #expect(info.haptic_intensity == 2 && info.trigger_intensity == 3)
        #expect(Self.padInfo("00 01 02") == nil)
    }
}
