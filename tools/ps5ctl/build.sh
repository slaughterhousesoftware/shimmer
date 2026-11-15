#!/bin/zsh
# Build tools/ps5ctl against the full (PSN) libchiaki. Output: build.noindex/ps5ctl
set -euo pipefail
ROOT=${0:A:h:h:h}
LIB=$ROOT/build.noindex/libchiaki/psn
$ROOT/scripts/build-libchiaki.sh psn >/dev/null
b() { brew --prefix $1; }
clang -O1 -g -arch arm64 -std=gnu11 -o $ROOT/build.noindex/ps5ctl $ROOT/tools/ps5ctl/ps5ctl.c \
  -I$LIB/include -I$ROOT/third_party/chiaki-ng/lib/include -I$(b curl)/include \
  $LIB/libchiaki.a \
  -L$(b openssl@3)/lib -lssl -lcrypto -L$(b opus)/lib -lopus \
  -L$(b curl)/lib -lcurl -L$(b json-c)/lib -ljson-c -L$(b libevent)/lib -levent \
  -L$(b miniupnpc)/lib -lminiupnpc -framework CoreServices -framework Security
echo "$ROOT/build.noindex/ps5ctl"
