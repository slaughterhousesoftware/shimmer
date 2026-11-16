//
//  Glimmer-Bridging-Header.h
//
//  Bridges the C libraries the Swift-native streaming engine depends on:
//  Opus (audio decode) and OpenSSL (Identity + Pairing + Network crypto),
//  plus our own inline C shims (CHelpers.h). Glimmer's streaming protocol
//  stack is pure Swift (Glimmer/Stream/Native/*).

#ifndef Glimmer_Bridging_Header_h
#define Glimmer_Bridging_Header_h

// Inline C shims (audio-config bit helpers + OpenSSL macro/variadic wrappers).
#import "Glimmer/Stream/CHelpers.h"

// Opus multistream decoder (audio path).
#import <opus/opus_multistream.h>

// OpenSSL primitives used by Identity + Pairing + Network.
// crypto.h explicitly for OPENSSL_thread_stop - the per-thread state release
// every pooled (GCD) thread that touches OpenSSL must run before it can be
// retired (see ControlTransport's defer; the 2026-08-21 TSD-destructor crash).
#import <openssl/crypto.h>
#import <openssl/bio.h>
#import <openssl/x509.h>
#import <openssl/pem.h>
#import <openssl/rand.h>
#import <openssl/aes.h>
#import <openssl/evp.h>
#import <openssl/sha.h>
#import <openssl/bn.h>
#import <openssl/pkcs12.h>
#import <openssl/err.h>
#import <openssl/ssl.h>

// chiaki-ng's libchiaki: the PS5 Remote Play engine behind PlayStationBackend
// (Glimmer/PlayStation). holepunch.h uses INET6_ADDRSTRLEN without including it.
#include <netinet/in.h>
#import <chiaki/common.h>
#import <chiaki/log.h>
#import <chiaki/session.h>
#import <chiaki/regist.h>
#import <chiaki/discovery.h>
#import <chiaki/controller.h>
#import <chiaki/orientation.h>
#import <chiaki/opusencoder.h>
// Shimmer's libchiaki patch (third_party/chiaki-ng-patches/0001): the AV
// reorder hold and debug video-packet loss injection, set before a session.
extern int chiaki_shimmer_reorder_timeout_us;
extern int chiaki_shimmer_drop_permille;
static inline void shimmer_set_takion_knobs(int reorder_timeout_us, int drop_permille) {
    chiaki_shimmer_reorder_timeout_us = reorder_timeout_us;
    chiaki_shimmer_drop_permille = drop_permille;
}
#import <chiaki/audioreceiver.h>
#import <chiaki/base64.h>

#endif
