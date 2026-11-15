#!/bin/zsh
# A self-contained ps5ctl for another Mac: the LAN libchiaki (no PSN commands)
# with OpenSSL and Opus linked statically; only system libraries remain.
# Use PS5CTL_REGIST_FILE there, since that Mac's keychain lacks the item.
set -euo pipefail
ROOT=${0:A:h:h:h}
LIB=$ROOT/build.noindex/libchiaki/lan
$ROOT/scripts/build-libchiaki.sh lan >/dev/null
b() { brew --prefix $1; }
clang -O1 -g -arch arm64 -std=gnu11 -mmacosx-version-min=26.0 -o $ROOT/build.noindex/ps5ctl-portable \
  $ROOT/tools/ps5ctl/ps5ctl.c -I$LIB/include -I$ROOT/third_party/chiaki-ng/lib/include \
  -isystem $(xcrun --show-sdk-path)/usr/include \
  $LIB/libchiaki.a $(b openssl@3)/lib/libssl.a $(b openssl@3)/lib/libcrypto.a $(b opus)/lib/libopus.a \
  -lcurl -framework CoreServices -framework Security
echo "$ROOT/build.noindex/ps5ctl-portable"
