#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${RUNNER_TEMP:-/tmp}/amethyst-v4-graphics"
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
MVK_TAG="v1.4.2"
MESA_VERSION="26.1.6"
MESA_SHA256="5296b88a0f1e012e2cb9ada150a2bbadf728ca81e5a4fb2ab43c83a4d2158606"
FRAMEWORKS="$ROOT/Natives/resources/Frameworks"
mkdir -p "$WORK" "$FRAMEWORKS"
rm -rf "$WORK/MoltenVK" "$WORK/mesa-$MESA_VERSION" "$WORK/mesa-build"

printf '\n=== Enhanced v4: preserve legacy Zink/MoltenVK recovery stack ===\n'
if [[ -f "$FRAMEWORKS/libMoltenVK.dylib" && ! -f "$FRAMEWORKS/libMoltenVKLegacy.dylib" ]]; then
  cp "$FRAMEWORKS/libMoltenVK.dylib" "$FRAMEWORKS/libMoltenVKLegacy.dylib"
  install_name_tool -id @rpath/libMoltenVKLegacy.dylib "$FRAMEWORKS/libMoltenVKLegacy.dylib" || true
fi
if [[ -f "$FRAMEWORKS/libOSMesa.8.dylib" ]]; then
  echo "Legacy Mesa before v4:"
  strings "$FRAMEWORKS/libOSMesa.8.dylib" | grep -m1 -E '^Mesa [0-9]' || true
  echo "Legacy Mesa linkage:"
  otool -L "$FRAMEWORKS/libOSMesa.8.dylib" || true
  # If the legacy Zink binary has a direct MoltenVK dependency, keep it attached
  # to the legacy copy. If it dlopens Vulkan instead, there is nothing safe to
  # rewrite here and the command intentionally becomes a no-op.
  if otool -L "$FRAMEWORKS/libOSMesa.8.dylib" | grep -q 'libMoltenVK.dylib'; then
    install_name_tool -change @rpath/libMoltenVK.dylib @rpath/libMoltenVKLegacy.dylib "$FRAMEWORKS/libOSMesa.8.dylib" || true
    install_name_tool -change libMoltenVK.dylib @rpath/libMoltenVKLegacy.dylib "$FRAMEWORKS/libOSMesa.8.dylib" || true
  fi
fi

printf '\n=== Enhanced v4: MoltenVK %s ===\n' "$MVK_TAG"
git clone --depth 1 --branch "$MVK_TAG" https://github.com/KhronosGroup/MoltenVK.git "$WORK/MoltenVK"
pushd "$WORK/MoltenVK"
./fetchDependencies --ios
xcodebuild build \
  -project MoltenVKPackaging.xcodeproj \
  -scheme "MoltenVK Package (iOS only)" \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

MVK_BIN="$(find Package -type f \( -name 'libMoltenVK.dylib' -o -path '*/MoltenVK.framework/MoltenVK' \) | grep -E 'ios-arm64|iOS|dynamic' | head -n 1 || true)"
if [[ -z "$MVK_BIN" ]]; then
  MVK_BIN="$(find Package -type f \( -name 'libMoltenVK.dylib' -o -path '*/MoltenVK.framework/MoltenVK' \) | head -n 1 || true)"
fi
if [[ -z "$MVK_BIN" ]]; then
  echo "Could not locate a dynamic iOS MoltenVK binary. Package tree:" >&2
  find Package -maxdepth 7 -type f | sort | head -300 >&2
  exit 21
fi
file "$MVK_BIN"
cp "$MVK_BIN" "$FRAMEWORKS/libMoltenVK.dylib"
install_name_tool -id @rpath/libMoltenVK.dylib "$FRAMEWORKS/libMoltenVK.dylib" || true
popd

printf '\n=== Enhanced v4: Mesa %s / Zink / OSMesa ===\n' "$MESA_VERSION"
curl -fL --retry 4 --retry-delay 2 \
  "https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz" \
  -o "$WORK/mesa-${MESA_VERSION}.tar.xz"
echo "$MESA_SHA256  $WORK/mesa-${MESA_VERSION}.tar.xz" | shasum -a 256 -c -
tar -xJf "$WORK/mesa-${MESA_VERSION}.tar.xz" -C "$WORK"

# Locate the packaged MoltenVK SDK directory. Mesa's moltenvk-dir option accepts
# a MoltenVK/Vulkan SDK tree and avoids pretending Apple's platform has a native
# system Vulkan loader.
MVK_SDK="$(find "$WORK/MoltenVK/Package" -type d -name 'MoltenVK.xcframework' -print -quit || true)"
if [[ -n "$MVK_SDK" ]]; then
  MVK_SDK="$(dirname "$MVK_SDK")"
else
  MVK_SDK="$WORK/MoltenVK"
fi
echo "Mesa moltenvk-dir: $MVK_SDK"

cat > "$WORK/ios-arm64.ini" <<EOF
[binaries]
c = ['xcrun', '--sdk', 'iphoneos', 'clang']
cpp = ['xcrun', '--sdk', 'iphoneos', 'clang++']
ar = ['xcrun', '--sdk', 'iphoneos', 'ar']
strip = ['xcrun', '--sdk', 'iphoneos', 'strip']
pkg-config = 'pkg-config'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[built-in options]
c_args = ['-arch', 'arm64', '-miphoneos-version-min=15.0', '-mcpu=apple-a13', '-O3']
cpp_args = ['-arch', 'arm64', '-miphoneos-version-min=15.0', '-mcpu=apple-a13', '-O3']
c_link_args = ['-arch', 'arm64', '-miphoneos-version-min=15.0', '-Wl,-dead_strip']
cpp_link_args = ['-arch', 'arm64', '-miphoneos-version-min=15.0', '-Wl,-dead_strip']
EOF

MESON_ARGS=(
  --cross-file "$WORK/ios-arm64.ini"
  --buildtype release
  -Db_ndebug=true
  -Ddefault_library=shared
  -Dplatforms=[]
  -Dglx=disabled
  -Degl=disabled
  -Dgbm=disabled
  -Dopengl=true
  -Dgles1=disabled
  -Dgles2=disabled
  -Dosmesa=true
  -Dgallium-drivers=zink
  -Dvulkan-drivers=[]
  -Dllvm=disabled
  -Dshared-glapi=enabled
  -Dbuild-tests=false
  -Dvalgrind=disabled
  -Dmoltenvk-dir="$MVK_SDK"
)

meson setup "$WORK/mesa-build" "$WORK/mesa-$MESA_VERSION" "${MESON_ARGS[@]}"
meson compile -C "$WORK/mesa-build" -j "$(sysctl -n hw.logicalcpu)"

MESA_BIN="$(find "$WORK/mesa-build" -type f -name 'libOSMesa*.dylib' | head -n 1 || true)"
if [[ -z "$MESA_BIN" ]]; then
  echo "Mesa build completed but no libOSMesa dylib was found." >&2
  find "$WORK/mesa-build" -type f | grep -E 'OSMesa|zink|dylib' | head -200 >&2 || true
  exit 22
fi
cp "$MESA_BIN" "$FRAMEWORKS/libOSMesaModern.8.dylib"
install_name_tool -id @rpath/libOSMesaModern.8.dylib "$FRAMEWORKS/libOSMesaModern.8.dylib" || true

# Ensure modern Mesa resolves Vulkan to the modern MoltenVK bundled in the app.
for dep in $(otool -L "$FRAMEWORKS/libOSMesaModern.8.dylib" | awk '/MoltenVK/{print $1}'); do
  install_name_tool -change "$dep" @rpath/libMoltenVK.dylib "$FRAMEWORKS/libOSMesaModern.8.dylib" || true
done

printf '\n=== Enhanced v4 graphics binary verification ===\n'
file "$FRAMEWORKS/libMoltenVK.dylib" "$FRAMEWORKS/libOSMesaModern.8.dylib"
echo 'MoltenVK version strings:'
strings "$FRAMEWORKS/libMoltenVK.dylib" | grep -m3 -E 'MoltenVK [0-9]|1\.4\.2' || true
echo 'Mesa version strings:'
strings "$FRAMEWORKS/libOSMesaModern.8.dylib" | grep -m3 -E '^Mesa [0-9]|26\.1\.6' || true
otool -L "$FRAMEWORKS/libOSMesaModern.8.dylib"

echo "Enhanced v4 graphics stack build complete."
