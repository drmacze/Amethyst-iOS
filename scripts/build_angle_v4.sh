#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${RUNNER_TEMP:-/tmp}/amethyst-v4-angle"
ANGLE_BRANCH="chromium/7871"
FRAMEWORKS="$ROOT/Natives/resources/Frameworks"
rm -rf "$WORK"
mkdir -p "$WORK" "$FRAMEWORKS"

printf '\n=== Enhanced v4: ANGLE Metal / %s ===\n' "$ANGLE_BRANCH"
# 7871 is the Chromium branch used by Chrome 150 Stable. ANGLE does not publish
# conventional release tags, so tracking the shipping Chromium stable branch is
# less risky than taking arbitrary `main`.
git clone --depth 1 --branch "$ANGLE_BRANCH" \
  https://chromium.googlesource.com/angle/angle "$WORK/angle"
pushd "$WORK/angle"

# Standalone ANGLE's bootstrap + gclient path is the supported way to obtain the
# exact DEPS revisions associated with this branch.
python3 scripts/bootstrap.py
export PATH="$PWD/../depot_tools:$PWD/depot_tools:$PATH"
if ! command -v gclient >/dev/null 2>&1; then
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$WORK/depot_tools"
  export PATH="$WORK/depot_tools:$PATH"
fi
gclient sync -D --no-history --shallow

mkdir -p out/ios-arm64
cat > out/ios-arm64/args.gn <<'EOF'
target_os = "ios"
target_cpu = "arm64"
target_environment = "device"
ios_enable_code_signing = false
is_component_build = false
is_debug = false
symbol_level = 0
angle_expose_non_conformant_extensions_and_versions = true
angle_build_tests = false
angle_standalone = false
angle_enable_gl = false
angle_enable_d3d9 = false
angle_enable_d3d11 = false
angle_enable_null = false
angle_enable_vulkan = false
angle_enable_wgpu = false
angle_enable_swiftshader = false
angle_enable_metal = true
angle_enable_essl = true
angle_enable_glsl = true
angle_has_frame_capture = false
build_angle_deqp_tests = false
angle_build_all = false
EOF

gn gen out/ios-arm64
autoninja -C out/ios-arm64 libEGL libGLESv2

EGL_BIN="$(find out/ios-arm64 -type f \( -name 'libEGL.dylib' -o -path '*/libEGL.framework/libEGL' \) | head -n1 || true)"
GLES_BIN="$(find out/ios-arm64 -type f \( -name 'libGLESv2.dylib' -o -path '*/libGLESv2.framework/libGLESv2' \) | head -n1 || true)"
if [[ -z "$EGL_BIN" || -z "$GLES_BIN" ]]; then
  echo "ANGLE build succeeded but expected dynamic libraries were not found." >&2
  find out/ios-arm64 -maxdepth 4 -type f | grep -E 'EGL|GLESv2' | head -200 >&2 || true
  exit 31
fi

mkdir -p "$FRAMEWORKS/libEGL.framework" "$FRAMEWORKS/libGLESv2.framework"
cp "$EGL_BIN" "$FRAMEWORKS/libEGL.framework/libEGL"
cp "$GLES_BIN" "$FRAMEWORKS/libGLESv2.framework/libGLESv2"
install_name_tool -id @rpath/libEGL.framework/libEGL "$FRAMEWORKS/libEGL.framework/libEGL" || true
install_name_tool -id @rpath/libGLESv2.framework/libGLESv2 "$FRAMEWORKS/libGLESv2.framework/libGLESv2" || true

printf '\n=== ANGLE binary verification ===\n'
file "$FRAMEWORKS/libEGL.framework/libEGL" "$FRAMEWORKS/libGLESv2.framework/libGLESv2"
otool -L "$FRAMEWORKS/libEGL.framework/libEGL" || true
otool -L "$FRAMEWORKS/libGLESv2.framework/libGLESv2" || true
popd

echo "Enhanced v4 ANGLE stable backend build complete."
