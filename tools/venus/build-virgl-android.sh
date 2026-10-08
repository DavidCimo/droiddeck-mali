#!/bin/bash
# The Android side of Venus: libepoxy + virglrenderer 1.3.0 (venus, vtest) for arm64 with the NDK.
# Run in WSL Ubuntu. Output: /home/delo/mali/android-out/{bin,libexec,lib}.
set -euo pipefail
W=/home/delo/mali
REPO=/mnt/c/Users/derab/source/repos/DroidDeck
NDK=/home/delo/android-sdk/ndk/27.3.13750724
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
API=29
OUT=$W/android-out
mkdir -p $W/cross $W/compat/log $W/compat/cutils $OUT/lib/pkgconfig
cd $W

[ -d libepoxy ] || git clone -q --depth 1 -b 1.5.10 https://github.com/anholt/libepoxy.git
[ -d Vulkan-Headers ] || git clone -q --depth 1 -b v1.4.365 https://github.com/KhronosGroup/Vulkan-Headers.git
if [ ! -d virglrenderer ]; then
  git clone -q --depth 1 -b virglrenderer-1.3.0 https://gitlab.freedesktop.org/virgl/virglrenderer.git
  git -C virglrenderer apply $REPO/tools/venus/virglrenderer-android.patch
fi

# virglrenderer's util code includes Android platform headers the NDK does not ship.
cat > $W/compat/log/log.h <<'EOF'
#pragma once
#include <android/log.h>
#define LOG_PRI(prio, tag, ...) __android_log_print(prio, tag, __VA_ARGS__)
EOF
cat > $W/compat/cutils/properties.h <<'EOF'
#pragma once
#include <string.h>
#include <sys/system_properties.h>
#define PROPERTY_VALUE_MAX PROP_VALUE_MAX
#define PROPERTY_KEY_MAX 32
static inline int property_get(const char *key, char *value, const char *def)
{
   int len = __system_property_get(key, value);
   if (len <= 0 && def) { strcpy(value, def); len = (int)strlen(def); }
   return len;
}
EOF

# The Khronos headers only; libvulkan is dlopened at runtime (vulkan-dload).
cat > $OUT/lib/pkgconfig/vulkan.pc <<EOF
prefix=$W/Vulkan-Headers
includedir=\${prefix}/include
Name: vulkan
Description: Vulkan headers
Version: 1.4.365
Cflags: -I\${includedir}
Libs: -lvulkan
EOF

cat > $W/cross/android.ini <<EOF
[binaries]
c = '$TC/aarch64-linux-android$API-clang'
cpp = '$TC/aarch64-linux-android$API-clang++'
ar = '$TC/llvm-ar'
strip = '$TC/llvm-strip'
pkg-config = '/usr/bin/pkg-config'

[built-in options]
c_args = ['-I$W/Vulkan-Headers/include', '-I$W/compat']
c_link_args = ['-llog', '-lnativewindow', '-Wl,-rpath=\$ORIGIN', '-Wl,-z,max-page-size=16384']
cpp_link_args = ['-Wl,-rpath=\$ORIGIN', '-Wl,-z,max-page-size=16384']

[properties]
pkg_config_libdir = '$OUT/lib/pkgconfig'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

export PKG_CONFIG_LIBDIR=$OUT/lib/pkgconfig
export PKG_CONFIG_PATH=

rm -rf epoxy-build
meson setup epoxy-build libepoxy --cross-file $W/cross/android.ini --prefix=$OUT --libdir=lib \
  --buildtype=release -Degl=yes -Dglx=no -Dx11=false -Dtests=false
ninja -C epoxy-build install

rm -rf virgl-build
meson setup virgl-build virglrenderer --cross-file $W/cross/android.ini --prefix=$OUT --libdir=lib \
  --buildtype=release -Dvenus=true -Dplatforms=auto -Drender-server-worker=thread \
  -Dvulkan-dload=true -Dcheck-gl-errors=false -Dtests=false
ninja -C virgl-build install
ls -la $OUT/bin $OUT/lib $OUT/libexec
