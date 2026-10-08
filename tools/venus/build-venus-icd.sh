#!/bin/bash
# The Linux side of Venus: Mesa 26.2.4's libvulkan_virtio.so for aarch64 glibc, cross-built in
# Debian trixie with tools/venus/mesa-venus-vtest.patch applied.
# Run from Git Bash on Windows with Docker Desktop up (its WSL integration is off):
#   MSYS_NO_PATHCONV=1 bash tools/venus/build-venus-icd.sh
# Output: C:/Users/derab/source/repos/droiddeck-mali/venus-out/usr/lib/libvulkan_virtio.so
# MEASURE=1 also applies measure-present.patch (per-frame present timings on stderr) and writes
# venus-out-measure/ instead, for a hand-installed test build.
set -euo pipefail
OUT=C:/Users/derab/source/repos/droiddeck-mali
VENUS=C:/Users/derab/source/repos/DroidDeck/tools/venus
DEST=venus-out
EXTRA_PATCH=
if [ "${MEASURE:-}" = 1 ]; then
  DEST=venus-out-measure
  EXTRA_PATCH=/venus/measure-present.patch
fi
docker run --rm --platform linux/amd64 -v "$OUT":/w -v "$VENUS":/venus:ro -w /tmp \
  -e DEST=$DEST -e EXTRA_PATCH=$EXTRA_PATCH debian:trixie bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture arm64
apt-get update -qq
apt-get install -y -qq --no-install-recommends git ca-certificates crossbuild-essential-arm64 meson ninja-build \
  pkg-config python3-mako python3-yaml python3-packaging bison flex glslang-tools libwayland-bin wayland-protocols \
  libdrm-dev:arm64 libwayland-dev:arm64 libx11-dev:arm64 libx11-xcb-dev:arm64 libxcb1-dev:arm64 \
  libxcb-dri3-dev:arm64 libxcb-present-dev:arm64 libxcb-randr0-dev:arm64 libxcb-shm0-dev:arm64 \
  libxcb-sync-dev:arm64 libxcb-xfixes0-dev:arm64 libxshmfence-dev:arm64 libxrandr-dev:arm64 \
  libexpat1-dev:arm64 zlib1g-dev:arm64 libzstd-dev:arm64 >/dev/null
cat > /tmp/arm64.ini <<EOF
[binaries]
c = '"'"'aarch64-linux-gnu-gcc'"'"'
cpp = '"'"'aarch64-linux-gnu-g++'"'"'
ar = '"'"'aarch64-linux-gnu-ar'"'"'
strip = '"'"'aarch64-linux-gnu-strip'"'"'
nm = '"'"'aarch64-linux-gnu-nm'"'"'
pkg-config = '"'"'pkg-config'"'"'

[properties]
pkg_config_libdir = ['"'"'/usr/lib/aarch64-linux-gnu/pkgconfig'"'"', '"'"'/usr/share/pkgconfig'"'"']

[host_machine]
system = '"'"'linux'"'"'
cpu_family = '"'"'aarch64'"'"'
cpu = '"'"'armv8-a'"'"'
endian = '"'"'little'"'"'
EOF
git clone -q --depth 1 -b mesa-26.2.4 https://gitlab.freedesktop.org/mesa/mesa.git 2>/dev/null
(cd mesa && git apply /venus/mesa-venus-vtest.patch)
if [ -n "$EXTRA_PATCH" ]; then (cd mesa && git apply "$EXTRA_PATCH"); fi
rm -rf /w/$DEST
meson setup venus-build mesa --cross-file /tmp/arm64.ini --prefix=/usr --libdir=lib \
  --buildtype=release -Db_ndebug=true \
  -Dvulkan-drivers=virtio -Dgallium-drivers= -Dplatforms=x11,wayland \
  -Dllvm=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
  -Dvideo-codecs= -Dvulkan-layers= -Dtools= -Dbuild-tests=false -Dvalgrind=disabled -Dlibunwind=disabled \
  -Dzstd=enabled -Dshared-glapi=disabled
ninja -C venus-build
DESTDIR=/w/$DEST ninja -C venus-build install
aarch64-linux-gnu-objdump -T /w/$DEST/usr/lib/libvulkan_virtio.so | grep -o "GLIBC_[0-9.]*" | sort -Vu | tail -1
'
