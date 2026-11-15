#!/bin/zsh
# Build chiaki-ng's libchiaki (third_party/chiaki-ng, AGPL-3.0 + OpenSSL exception)
# as a static library for Shimmer's PS5 Remote Play path. No cmake: the source
# list mirrors third_party/chiaki-ng/lib/CMakeLists.txt.
#
#   scripts/build-libchiaki.sh [lan|psn] [out-dir]
#
#   lan (default) - for Shimmer.app. PSN hole-punching is replaced by
#                   Glimmer/PlayStation/chiaki_holepunch_stub.c (direct LAN /
#                   Tailscale connections only), so the app needs no curl
#                   WebSockets, json-c, libevent or miniupnpc. aia.c still uses
#                   curl for plain HTTPS, which macOS's own libcurl provides.
#   psn           - full libchiaki including holepunch.c, linked against
#                   Homebrew curl/json-c/libevent/miniupnpc. Used by the
#                   developer tool (tools/ps5ctl) for PIN-less PSN registration.
set -euo pipefail

MODE=${1:-lan}
ROOT=${0:A:h:h}
CHIAKI=$ROOT/third_party/chiaki-ng
OUT=${2:-$ROOT/build.noindex/libchiaki/$MODE}
MIN_MACOS=${MACOSX_DEPLOYMENT_TARGET:-26.0}
OPENSSL=$(brew --prefix openssl@3)
OPUS=$(brew --prefix opus)

[[ -f $CHIAKI/lib/src/session.c ]] || { echo "chiaki-ng submodule missing: git submodule update --init --depth 1 third_party/chiaki-ng" >&2; exit 1; }
for sub in nanopb jerasure gf-complete; do
  [[ -n $(ls -A $CHIAKI/third-party/$sub 2>/dev/null) ]] || git -C $CHIAKI submodule update --init --depth 1 third-party/$sub
done

mkdir -p $OUT/obj $OUT/gen $OUT/include/chiaki

# config.h (cmakedefine01 -> 0/1)
sed -e 's/#cmakedefine01 CHIAKI_LIB_ENABLE_OPUS/#define CHIAKI_LIB_ENABLE_OPUS 1/' \
    -e 's/#cmakedefine01 CHIAKI_LIB_ENABLE_PI_DECODER/#define CHIAKI_LIB_ENABLE_PI_DECODER 0/' \
    -e 's/#cmakedefine01 CHIAKI_LIB_ENABLE_FFMPEG_DECODER/#define CHIAKI_LIB_ENABLE_FFMPEG_DECODER 0/' \
    $CHIAKI/lib/config.h.in > $OUT/include/chiaki/config.h.new
cmp -s $OUT/include/chiaki/config.h.new $OUT/include/chiaki/config.h 2>/dev/null \
  && rm $OUT/include/chiaki/config.h.new || mv $OUT/include/chiaki/config.h.new $OUT/include/chiaki/config.h

# takion.pb.{c,h} from the pinned takion.proto with the bundled nanopb generator.
PROTO=$CHIAKI/lib/protobuf/takion.proto
if [[ ! -f $OUT/gen/takion.pb.c || $PROTO -nt $OUT/gen/takion.pb.c ]]; then
  protoc -o$OUT/gen/takion.pb -I$CHIAKI/lib/protobuf $PROTO
  (cd $OUT/gen && uv run --quiet --with protobuf --with grpcio-tools python \
     $CHIAKI/third-party/nanopb/generator/nanopb_generator.py takion.pb >/dev/null)
fi

SOURCES=(
  common sock session thread base64 http log ctrl rpcrypt takion senkusha
  streamconnection ecdh launchspec random gkcrypt audio audioreceiver audiosender
  videoreceiver frameprocessor packetstats discovery congestioncontrol stoppipe
  reorderqueue discoveryservice feedback feedbacksender controller takionsendbuffer
  time fec regist opusdecoder opusencoder orientation bitstream aia aia_openssl
)
FILES=(${SOURCES/#/$CHIAKI/lib/src/})
FILES=(${FILES/%/.c} $CHIAKI/lib/src/remote/rudp.c $CHIAKI/lib/src/remote/rudpsendbuffer.c $OUT/gen/takion.pb.c)
FILES+=($CHIAKI/third-party/nanopb/{pb_common,pb_decode,pb_encode}.c)
FILES+=($CHIAKI/third-party/gf-complete/src/{gf,gf_wgen,gf_w4,gf_w8,gf_w16,gf_w32,gf_w64,gf_w128,gf_rand,gf_general,gf_cpu}.c)
FILES+=($CHIAKI/third-party/jerasure/src/{galois,jerasure,reed_sol,cauchy,liberation}.c)

CFLAGS=(-O2 -g -arch arm64 -mmacosx-version-min=$MIN_MACOS -std=gnu11
  -I$OUT/include -I$CHIAKI/lib/include -I$OUT/gen -I$CHIAKI/third-party/nanopb
  -I$CHIAKI/third-party/gf-complete/include -I$CHIAKI/third-party/jerasure/include
  -I$OPENSSL/include -I$OPUS/include -DPB_C99_STATIC_ASSERT
  -Wno-unused-function -Wno-unused-variable -Wno-deprecated-declarations
  -Wno-incompatible-pointer-types-discards-qualifiers -Wno-int-conversion)

if [[ $MODE == psn ]]; then
  CURL=$(brew --prefix curl)
  CFLAGS+=(-I$CURL/include -I$(brew --prefix json-c)/include -I$(brew --prefix libevent)/include -I$(brew --prefix miniupnpc)/include)
  FILES+=($CHIAKI/lib/src/remote/holepunch.c)
else
  CFLAGS+=(-isystem $(xcrun --show-sdk-path)/usr/include)
  FILES+=($ROOT/Glimmer/PlayStation/chiaki_holepunch_stub.c)
fi

OBJS=()
pids=()
for f in $FILES; do
  o=$OUT/obj/${${f:t}%.c}.o
  OBJS+=($o)
  if [[ ! -f $o || $f -nt $o || $OUT/include/chiaki/config.h -nt $o ]]; then
    clang $CFLAGS -c $f -o $o &
    pids+=($!)
    (( ${#pids} >= 10 )) && { wait $pids[1]; pids=(${pids[2,-1]}); }
  fi
done
for p in $pids; do wait $p; done

rm -f $OUT/libchiaki.a
libtool -static -o $OUT/libchiaki.a $OBJS 2>/dev/null
echo "libchiaki ($MODE): $OUT/libchiaki.a"
