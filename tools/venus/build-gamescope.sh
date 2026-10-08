#!/bin/bash
# gamescope with tools/gamescope/patches, built as .github/workflows/build-gamescope.yml does it, but
# locally in an emulated arm64 container (slow: most of an hour).
# Run from Git Bash on Windows with Docker Desktop up:
#   MSYS_NO_PATHCONV=1 bash tools/venus/build-gamescope.sh
# Output: C:/Users/derab/source/repos/droiddeck-mali/gamescope, which build-apk.sh stages.
set -euo pipefail
OUT=C:/Users/derab/source/repos/droiddeck-mali
REPO=C:/Users/derab/source/repos/DroidDeck
W=$OUT/gamescope-build
rm -rf "$W" && mkdir -p "$W/tools"
cp -r "$REPO/tools/gamescope" "$W/tools/"
# The Windows checkout is CRLF, which breaks the build script and the patches.
find "$W/tools" -type f -exec sed -i 's/\r$//' {} +
docker run --rm --platform linux/arm64 -v "$W":/work -w /work menci/archlinuxarm:base-devel \
  bash tools/gamescope/build-in-arch.sh
cp "$W/out/usr/local/bin/gamescope" "$OUT/gamescope"
ls -l "$OUT/gamescope"
