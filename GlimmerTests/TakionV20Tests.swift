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
}
