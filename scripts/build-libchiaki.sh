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

# Shimmer's changes to libchiaki live in third_party/chiaki-ng-patches/*.patch
# (unified diffs against the submodule, applied in name order). They are
# applied to copies under $OUT/patched, so the submodule stays pristine; a
# patched file compiles from there. Unchanged copies keep their mtime, so an
# unrelated build doesn't recompile them.
# research/*.patch (raw ctrl messages, launch-spec edits) is for ps5ctl only:
# applied in the psn build, never in the app's.
PATCHED=$OUT/patched
rm -rf $PATCHED.new && mkdir -p $PATCHED.new
PATCHES=($ROOT/third_party/chiaki-ng-patches/*.patch(N))
[[ $MODE == psn ]] && PATCHES+=($ROOT/third_party/chiaki-ng-patches/research/*.patch(N))
for p in $PATCHES; do
  for rel in ${(f)"$(sed -n 's|^+++ b/\([^[:space:]]*\).*|\1|p' $p)"}; do
    [[ -f $PATCHED.new/$rel ]] || { mkdir -p $PATCHED.new/${rel:h}; cp $CHIAKI/$rel $PATCHED.new/$rel; }
  done
  patch -s -d $PATCHED.new -p1 < $p || { echo "libchiaki patch failed: ${p:t}" >&2; exit 1; }
done
for f in $PATCHED.new/**/*(.N); do
  rel=${f#$PATCHED.new/}
  cmp -s $f $PATCHED/$rel 2>/dev/null && cp -p $PATCHED/$rel $f
done
rm -rf $PATCHED && mv $PATCHED.new $PATCHED

# Public headers: the whole of lib/include/chiaki, with the patched copies on
# top, in $OUT/include/chiaki - the first include path of this build, the app
# (Glimmer/StreamLib.xcconfig) and ps5ctl. All of them, not just the patched
# ones: chiaki's headers include each other with quotes, which resolves next
# to the including file first, so a lone patched takion.h beside pristine
# session.h would never be seen. Patches change struct layouts (ChiakiTakion,
# ChiakiSession), so every compiler of this library must see the same ones.
for h in $CHIAKI/lib/include/chiaki/**/*.h; do
  rel=${h#$CHIAKI/lib/include/}
  [[ $rel == chiaki/config.h ]] && continue # generated below from config.h.in
  src=$h
  [[ -f $PATCHED/lib/include/$rel ]] && src=$PATCHED/lib/include/$rel
  mkdir -p $OUT/include/${rel:h}
  cmp -s $src $OUT/include/$rel 2>/dev/null || cp $src $OUT/include/$rel
done

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
  -I$OUT/include -I$CHIAKI/lib/include -I$CHIAKI/lib/src -I$OUT/gen -I$CHIAKI/third-party/nanopb
  -I$CHIAKI/third-party/gf-complete/include -I$CHIAKI/third-party/jerasure/include
  -I$OPENSSL/include -I$OPUS/include -DPB_C99_STATIC_ASSERT
  -Wno-unused-function -Wno-unused-variable -Wno-deprecated-declarations
  -Wno-incompatible-pointer-types-discards-qualifiers -Wno-int-conversion)

# Extra flags for an instrumented copy, e.g.
#   SHIMMER_LIBCHIAKI_CFLAGS=-fsanitize=address scripts/build-libchiaki.sh lan build.noindex/libchiaki/lan-asan
CFLAGS+=(${=SHIMMER_LIBCHIAKI_CFLAGS:-})

if [[ $MODE == psn ]]; then
  CURL=$(brew --prefix curl)
  CFLAGS+=(-I$CURL/include -I$(brew --prefix json-c)/include -I$(brew --prefix libevent)/include -I$(brew --prefix miniupnpc)/include)
  FILES+=($CHIAKI/lib/src/remote/holepunch.c)
else
  CFLAGS+=(-isystem $(xcrun --show-sdk-path)/usr/include)
  FILES+=($ROOT/Glimmer/PlayStation/chiaki_holepunch_stub.c)
fi

for i in {1..${#FILES}}; do
  rel=${FILES[$i]#$CHIAKI/}
  [[ -f $PATCHED/$rel ]] && FILES[$i]=$PATCHED/$rel
done

# Any public header changing (a patch, config.h) rebuilds everything.
NEWEST_HEADER=($OUT/include/chiaki/**/*.h(om[1]))
# A source that reaches a public header by relative path ("../include/...")
# bypasses $OUT/include and compiles against the unpatched layouts - silent
# memory corruption (videoreceiver.c did, until patch 0002). Refuse to build.
bad=$(grep -l '#include "\.\./include/' $FILES 2>/dev/null || true)
[[ -z $bad ]] || { echo "libchiaki: relative public-header include in: $bad" >&2; exit 1; }

OBJS=()
pids=()
for f in $FILES; do
  o=$OUT/obj/${${f:t}%.c}.o
  OBJS+=($o)
  # .src records which copy (pristine or patched) built the object: a file
  # that gains or loses a patch must rebuild even if its mtime is older.
  if [[ ! -f $o || $f -nt $o || $NEWEST_HEADER -nt $o || "$(cat $o.src 2>/dev/null)" != $f ]]; then
    print -r -- $f > $o.src
    clang $CFLAGS -c $f -o $o &
    pids+=($!)
    (( ${#pids} >= 10 )) && { wait $pids[1]; pids=(${pids[2,-1]}); }
  fi
done
for p in $pids; do wait $p; done

rm -f $OUT/libchiaki.a
libtool -static -o $OUT/libchiaki.a $OBJS 2>/dev/null
echo "libchiaki ($MODE): $OUT/libchiaki.a"
