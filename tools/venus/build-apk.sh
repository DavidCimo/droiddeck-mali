#!/bin/bash
# Builds and signs the Mali (Venus) prototype APK. Run in WSL Ubuntu:
#   bash /mnt/c/Users/derab/source/repos/DroidDeck/tools/venus/build-apk.sh 10
# Before it, on Windows (Git Bash), export the source changes as an LF patch:
#   cd /c/Users/derab/source/repos/DroidDeck && git diff 0.3.1 > ../droiddeck-mali/venus.patch
# The Windows checkout is CRLF, which breaks gradlew and the session scripts, so the build runs in
# a clean LF clone at /home/delo/DroidDeck with that patch applied.
# Output: C:/Users/derab/source/repos/droiddeck-mali/DroidDeck-0.3.1-mali-venus-<n>.apk
set -euo pipefail
N=${1:?build number}
MALI=/mnt/c/Users/derab/source/repos/droiddeck-mali
B=/home/delo/DroidDeck
SDK=/home/delo/android-sdk
NDKV=27.3.13750724
APK=DroidDeck-0.3.1-mali-venus-$N.apk

if [ ! -d $B/.git ]; then
  git clone -q -c core.autocrlf=false https://github.com/Droid-Deck/DroidDeck.git $B
fi
cd $B
git checkout -q -f 0.3.1
git clean -qfdx -e app/build -e .gradle -e build
git apply $MALI/venus.patch

# What the full CI pipeline builds with Docker and gh releases, taken from the official 0.3.1 APK.
rel=/tmp/rel031
rm -rf $rel && mkdir -p $rel
unzip -q $MALI/DroidDeck-0.3.1.apk 'assets/linuxfs/*' 'assets/droiddeck-esync/*' 'assets/pulseaudio.tzst' \
  'lib/arm64-v8a/libproot.so' 'lib/arm64-v8a/libproot-loader.so' -d $rel
mkdir -p app/src/main/assets app/src/main/jniLibs/arm64-v8a
cp -a $rel/assets/linuxfs $rel/assets/droiddeck-esync app/src/main/assets/
cp $rel/assets/pulseaudio.tzst app/src/main/assets/pulseaudio.tzst
cp $rel/lib/arm64-v8a/libproot.so $rel/lib/arm64-v8a/libproot-loader.so app/src/main/jniLibs/arm64-v8a/
cp $MALI/libblsession.so app/src/main/assets/linuxfs/libblsession.so

# Venus: the vtest server (bionic) as native libraries, the ICD (glibc) as an asset.
A=/home/delo/mali/android-out
cp $A/bin/virgl_test_server app/src/main/jniLibs/arm64-v8a/libvirgl_test_server.so
cp $A/libexec/virgl_render_server app/src/main/jniLibs/arm64-v8a/libvirgl_render_server.so
cp $A/lib/libvirglrenderer.so $A/lib/libepoxy.so app/src/main/jniLibs/arm64-v8a/
mkdir -p app/src/main/assets/venus
cp $MALI/venus-out/usr/lib/libvulkan_virtio.so app/src/main/assets/venus/

export ANDROID_HOME=$SDK ANDROID_SDK_ROOT=$SDK JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
echo "sdk.dir=$SDK" > local.properties
chmod +x gradlew
./gradlew assembleRelease --console=plain -PndkVersion=$NDKV 2>&1 | tail -20

BT=$SDK/build-tools/34.0.0
$BT/zipalign -p -f 4 app/build/outputs/apk/release/app-release.apk /tmp/aligned.apk
$BT/apksigner sign --ks keystore/testkey.p12 --ks-type PKCS12 --ks-pass pass:android \
  --ks-key-alias testkey --key-pass pass:android --out $MALI/$APK /tmp/aligned.apk
$BT/apksigner verify $MALI/$APK && echo "signed: $MALI/$APK"
