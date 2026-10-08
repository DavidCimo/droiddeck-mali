#!/bin/bash
# The Mali compatibility layer (tools/venus/layer) for aarch64 glibc, with its manifest.
# Run from Git Bash on Windows with Docker Desktop up:
#   MSYS_NO_PATHCONV=1 bash tools/venus/build-layer.sh
# Output: C:/Users/derab/source/repos/droiddeck-mali/layer/, which build-apk.sh stages.
set -euo pipefail
OUT=C:/Users/derab/source/repos/droiddeck-mali
LAYER=C:/Users/derab/source/repos/DroidDeck/tools/venus/layer
docker run --rm --platform linux/amd64 -v "$OUT":/out -v "$LAYER":/src:ro debian:trixie bash -c '
set -euo pipefail
apt-get update -qq
apt-get install -y -qq --no-install-recommends gcc-aarch64-linux-gnu libc6-dev-arm64-cross git ca-certificates curl >/dev/null
SDK=vulkan-sdk-1.4.357.0
git -c advice.detachedHead=false clone -q --depth 1 -b $SDK https://github.com/KhronosGroup/Vulkan-Headers.git /tmp/vulkan
git -c advice.detachedHead=false clone -q --depth 1 -b $SDK https://github.com/KhronosGroup/SPIRV-Headers.git /tmp/spirv
mkdir -p /tmp/bcdec /out/layer
curl -sSfL -o /tmp/bcdec/bcdec.h https://raw.githubusercontent.com/iOrange/bcdec/80859ed3b7afb1c527a2a99d70c61457bea72d0c/bcdec.h
aarch64-linux-gnu-gcc -shared -fPIC -O2 -Wall -Wextra -Wno-unused-parameter -fvisibility=hidden -pthread \
  -I/tmp/vulkan/include -I/tmp/spirv/include -I/tmp/bcdec \
  -o /out/layer/libVkLayer_droiddeck_mali_compat.so /src/*.c
aarch64-linux-gnu-strip --strip-unneeded /out/layer/libVkLayer_droiddeck_mali_compat.so
cp /src/VkLayer_droiddeck_mali_compat.json /out/layer/
aarch64-linux-gnu-objdump -T /out/layer/libVkLayer_droiddeck_mali_compat.so | grep -o "GLIBC_[0-9.]*" | sort -Vu | tail -1
'
ls -l "$OUT/layer"
