#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${RUNNER_TEMP:-/tmp}/amethyst-v4-graphics"
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
MVK_TAG="v1.4.2"
# Mesa 25.0.7 is intentionally the modern OSMesa/Zink compatibility baseline.
# Mesa removed the OSMesa frontend in 25.1, while Amethyst's iOS Zink bridge
# still loads libOSMesa. Keep newer Mesa migration separate until the launcher
# has a non-OSMesa presentation frontend.
MESA_VERSION="25.0.7"
MESA_SHA256="592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6"
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

printf '\n=== Enhanced v4: Mesa %s / OSMesa-Zink / MoltenVK ===\n' "$MESA_VERSION"
curl -fL --retry 4 --retry-delay 2 \
  "https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz" \
  -o "$WORK/mesa-${MESA_VERSION}.tar.xz"
echo "$MESA_SHA256  $WORK/mesa-${MESA_VERSION}.tar.xz" | shasum -a 256 -c -
tar -xJf "$WORK/mesa-${MESA_VERSION}.tar.xz" -C "$WORK"

# Fail with an explicit diagnosis if this compatibility frontend disappears
# instead of feeding an invalid option to Meson and wasting another full CI run.
MESA_OPTIONS="$WORK/mesa-$MESA_VERSION/meson_options.txt"
if [[ ! -f "$MESA_OPTIONS" ]] || ! grep -q "'osmesa'" "$MESA_OPTIONS"; then
  echo "Mesa $MESA_VERSION does not expose the OSMesa frontend required by Amethyst's current Zink bridge." >&2
  exit 23
fi
if ! grep -q "'zink'" "$MESA_OPTIONS" || ! grep -q "'softpipe'" "$MESA_OPTIONS"; then
  echo "Mesa $MESA_VERSION does not expose the required Zink + softpipe Gallium driver combination." >&2
  exit 24
fi

# Mesa's moltenvk-dir option expects the MoltenVK SDK root that contains
# include/, not the dynamic/ XCFramework directory itself. MoltenVK's package
# layout is Package/Release/MoltenVK/{include,dynamic,static}.
MVK_SDK="$WORK/MoltenVK/Package/Release/MoltenVK"
if [[ ! -d "$MVK_SDK/include" ]]; then
  MVK_SDK="$WORK/MoltenVK/Package/Latest/MoltenVK"
fi
if [[ ! -d "$MVK_SDK/include" ]]; then
  echo "Could not locate MoltenVK SDK include directory. Package tree:" >&2
  find "$WORK/MoltenVK/Package" -maxdepth 5 -type d | sort | head -200 >&2
  exit 26
fi
echo "Mesa moltenvk-dir: $MVK_SDK"
find "$MVK_SDK/include" -maxdepth 3 -type f | head -30

# Mesa's generated Vulkan dispatch table contains both the legacy MoltenVK iOS
# surface entry points and the modern VK_EXT_metal_surface / metal-objects entry
# points. Vulkan headers expose those declarations only when these platform guard
# macros are enabled. Keep them target-wide so every generated Zink TU sees the
# same Vulkan ABI declarations.
VK_IOS_DEFINES="-DVK_USE_PLATFORM_IOS_MVK -DVK_USE_PLATFORM_METAL_EXT"

cat > "$WORK/ios-arm64.ini" <<EOF
[binaries]
c = ['xcrun', '--sdk', 'iphoneos', 'clang']
cpp = ['xcrun', '--sdk', 'iphoneos', 'clang++']
objc = ['xcrun', '--sdk', 'iphoneos', 'clang']
objcpp = ['xcrun', '--sdk', 'iphoneos', 'clang++']
ar = ['xcrun', '--sdk', 'iphoneos', 'ar']
strip = ['xcrun', '--sdk', 'iphoneos', 'strip']
pkg-config = 'pkg-config'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[built-in options]
c_args = ['-arch', 'arm64', '-miphoneos-version-min=15.0', '-mcpu=apple-a13', '-O3', '-DVK_USE_PLATFORM_IOS_MVK', '-DVK_USE_PLATFORM_METAL_EXT']
cpp_args = ['-arch', 'arm64', '-miphoneos-version-min=15.0', '-mcpu=apple-a13', '-O3', '-DVK_USE_PLATFORM_IOS_MVK', '-DVK_USE_PLATFORM_METAL_EXT']
objc_args = ['-arch', 'arm64', '-miphoneos-version-min=15.0', '-mcpu=apple-a13', '-O3', '-DVK_USE_PLATFORM_IOS_MVK', '-DVK_USE_PLATFORM_METAL_EXT']
objcpp_args = ['-arch', 'arm64', '-miphoneos-version-min=15.0', '-mcpu=apple-a13', '-O3', '-DVK_USE_PLATFORM_IOS_MVK', '-DVK_USE_PLATFORM_METAL_EXT']
c_link_args = ['-arch', 'arm64', '-miphoneos-version-min=15.0', '-Wl,-dead_strip']
cpp_link_args = ['-arch', 'arm64', '-miphoneos-version-min=15.0', '-Wl,-dead_strip']
objc_link_args = ['-arch', 'arm64', '-miphoneos-version-min=15.0', '-Wl,-dead_strip']
objcpp_link_args = ['-arch', 'arm64', '-miphoneos-version-min=15.0', '-Wl,-dead_strip']
EOF

# OSMesa in Mesa 25.0 requires at least one software Gallium driver to build
# its frontend. Include softpipe only to satisfy that frontend dependency;
# Amethyst explicitly exports GALLIUM_DRIVER=zink before loading the modern
# renderer, and Mesa's sw_screen_create() honours that explicit driver first.
# Vulkan itself is supplied by MoltenVK, so no Mesa native Vulkan driver or
# desktop WSI platform belongs in this iOS build.
MESON_ARGS=(
  --cross-file "$WORK/ios-arm64.ini"
  --buildtype release
  -Db_ndebug=true
  -Ddefault_library=shared
  -Dplatforms=
  -Dglx=disabled
  -Degl=disabled
  -Dgbm=disabled
  -Dopengl=true
  -Dgles1=disabled
  -Dgles2=disabled
  -Dosmesa=true
  -Dgallium-drivers=softpipe,zink
  -Dvulkan-drivers=
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

for dep in $(otool -L "$FRAMEWORKS/libOSMesaModern.8.dylib" | awk '/MoltenVK/{print $1}'); do
  install_name_tool -change "$dep" @rpath/libMoltenVK.dylib "$FRAMEWORKS/libOSMesaModern.8.dylib" || true
done

printf '\n=== Enhanced v4 graphics binary verification ===\n'
file "$FRAMEWORKS/libMoltenVK.dylib" "$FRAMEWORKS/libOSMesaModern.8.dylib"
echo 'MoltenVK version strings:'
strings "$FRAMEWORKS/libMoltenVK.dylib" | grep -m3 -E 'MoltenVK [0-9]|1\.4\.2' || true
echo 'Mesa version strings:'
strings "$FRAMEWORKS/libOSMesaModern.8.dylib" | grep -m3 -E '^Mesa [0-9]|25\.0\.7' || true
echo 'Modern OSMesa linkage:'
otool -L "$FRAMEWORKS/libOSMesaModern.8.dylib"
if ! strings "$FRAMEWORKS/libOSMesaModern.8.dylib" | grep -q 'zink'; then
  echo "Built libOSMesa does not contain Zink symbols/strings; refusing to package a mislabeled software renderer." >&2
  exit 25
fi

echo "Enhanced v4 graphics stack build complete."
