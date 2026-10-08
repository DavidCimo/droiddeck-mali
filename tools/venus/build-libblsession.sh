#!/bin/bash
# The session preload (tools/linuxfs/preload/*.c, venus.c included) for aarch64 glibc.
# The APK build otherwise takes libblsession.so from the official 0.3.1 APK, which lacks venus.c.
# Run from Git Bash on Windows with Docker Desktop up:
#   MSYS_NO_PATHCONV=1 bash tools/venus/build-libblsession.sh
# Output: C:/Users/derab/source/repos/droiddeck-mali/libblsession.so
set -euo pipefail
docker run --rm --platform linux/amd64 \
  -v "C:/Users/derab/source/repos/DroidDeck/tools/linuxfs/preload:/src:ro" \
  -v "C:/Users/derab/source/repos/droiddeck-mali:/out" debian:trixie bash -c '
set -e
apt-get update -qq
apt-get install -y -qq --no-install-recommends gcc-aarch64-linux-gnu libc6-dev-arm64-cross >/dev/null
aarch64-linux-gnu-gcc -shared -fPIC -O2 -Wall -pthread -o /out/libblsession.so /src/*.c -ldl
aarch64-linux-gnu-strip --strip-unneeded /out/libblsession.so
'
