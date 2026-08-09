#!/usr/bin/env python3
"""Prepare the Amethyst Enhanced v2 CI build.

The Enhanced branch keeps upstream launcher code easy to rebase. This script
applies the small build/runtime deltas that are specific to the A13 performance
artifact: MobileGlues 2.x layout, Release/LTO build, A13 codegen, a safer
headroom-aware Auto RAM policy, and MobileGlues as the Enhanced Auto renderer.
"""

from pathlib import Path
import os
import plistlib

ROOT = Path(__file__).resolve().parents[1]
MAKEFILE = ROOT / "Makefile"
INFO_PLIST = ROOT / "Natives" / "Info.plist"
CMAKE = ROOT / "Natives" / "CMakeLists.txt"
JAVA_LAUNCHER = ROOT / "Natives" / "JavaLauncher.m"
CPU_TARGET = os.environ.get("AMETHYST_CPU_TARGET", "apple-a13").strip() or "apple-a13"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"prepare_enhanced_build: {message}")


# MobileGlues 2.x moved its native CMake project from src/main/cpp to
# MobileGlues-cpp and now links SPIRV-Cross statically.
text = MAKEFILE.read_text(encoding="utf-8")
old_src = "$(SOURCEDIR)/Natives/external/MobileGlues/src/main/cpp/"
new_src = "$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/"
require(old_src in text or new_src in text, "unknown MobileGlues source layout in Makefile")
text = text.replace(old_src, new_src)

require("dep_mg:" in text, "dep_mg target missing")
head, dep = text.split("dep_mg:", 1)

# Single-config CMake generators ignore --config for selecting optimization,
# so explicitly configure MobileGlues as Release. MobileGlues 2.x then enables
# its supported non-Debug IPO/ThinLTO path when AppleClang supports it.
if "-DCMAKE_BUILD_TYPE=Release" not in dep:
    needle = "\t\t-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \\\n"
    require(needle in dep, "could not locate MobileGlues CMake deployment-target line")
    dep = dep.replace(
        needle,
        needle + "\t\t-DCMAKE_BUILD_TYPE=Release \\\n",
        1,
    )

# A13 artifact: compile both C and C++ renderer translation units for Apple A13.
# This is intentionally limited to the Enhanced-A13 IPA rather than silently
# changing the architecture contract of upstream's generic build.
old_cflags = '\t\t-DCMAKE_C_FLAGS="-arch arm64" \\\n'
new_cflags = (
    f'\t\t-DCMAKE_C_FLAGS="-arch arm64 -mcpu={CPU_TARGET}" \\\n'
    f'\t\t-DCMAKE_CXX_FLAGS="-arch arm64 -mcpu={CPU_TARGET}" \\\n'
)
require(old_cflags in dep or f"-mcpu={CPU_TARGET}" in dep, "could not locate MobileGlues C flags")
if old_cflags in dep:
    dep = dep.replace(old_cflags, new_cflags, 1)

dep = dep.replace(
    "cmake --build $(WORKINGDIR)/mobileglues --config RelWithDebInfo",
    "cmake --build $(WORKINGDIR)/mobileglues --config Release",
)

# MobileGlues 2.x has SPIRV_CROSS_STATIC=ON; the old standalone dylib path no
# longer exists and should not be packaged.
dep_lines = [line for line in dep.splitlines() if "libspirv-cross-c-shared.0.dylib" not in line]
text = head + "dep_mg:" + "\n".join(dep_lines)
if not text.endswith("\n"):
    text += "\n"
MAKEFILE.write_text(text, encoding="utf-8")

# The native Amethyst target exposes AMETHYST_CPU_TARGET in v2's CMakeLists.
cmake = CMAKE.read_text(encoding="utf-8")
needle = 'set(AMETHYST_CPU_TARGET "apple-a8")'
replacement = f'set(AMETHYST_CPU_TARGET "{CPU_TARGET}")'
require(needle in cmake or replacement in cmake, "AMETHYST_CPU_TARGET hook missing from CMakeLists")
cmake = cmake.replace(needle, replacement, 1)
CMAKE.write_text(cmake, encoding="utf-8")

# Replace fixed-percent Auto RAM with an app-limit-aware cap. Apple's
# os_proc_available_memory() reports the current process headroom, which is much
# more useful on iOS than physical RAM alone. We retain the old physical-memory
# ratio as the upper bound and reserve native/rendering headroom for Metal,
# MobileGlues, LWJGL and iOS itself.
java = JAVA_LAUNCHER.read_text(encoding="utf-8")
if "#include <os/proc.h>" not in java:
    include_anchor = "#include <unistd.h>\n"
    require(include_anchor in java, "JavaLauncher include anchor missing")
    java = java.replace(include_anchor, include_anchor + "#include <os/proc.h>\n", 1)

old_ram = '''    int allocmem;
    if (getPrefBool(@"java.auto_ram")) {
        CGFloat autoRatio = getEntitlementValue(@"com.apple.private.memorystatus") ? 0.4 : 0.25;
        allocmem = roundf((NSProcessInfo.processInfo.physicalMemory >> 20) * autoRatio);
    } else {
        allocmem = getPrefInt(@"java.allocated_memory");
    }
    NSLog(@"[JavaLauncher] Max RAM allocation is set to %d MB", allocmem);
'''
new_ram = '''    int allocmem;
    if (getPrefBool(@"java.auto_ram")) {
        CGFloat autoRatio = getEntitlementValue(@"com.apple.private.memorystatus") ? 0.4 : 0.25;
        int physicalBasedMB = roundf((NSProcessInfo.processInfo.physicalMemory >> 20) * autoRatio);
        size_t availableBytes = os_proc_available_memory();
        int availableMB = (int)(availableBytes >> 20);
        if (availableMB > 0) {
            // Keep a dynamic native reserve. This prevents Auto RAM from handing
            // the Java heap memory that Metal/LWJGL/the renderer still need.
            int reserveMB = MAX(320, MIN(512, availableMB / 3));
            int headroomBasedMB = MAX(384, availableMB - reserveMB);
            allocmem = MIN(physicalBasedMB, headroomBasedMB);
            NSLog(@"[EnhancedMemory] iOS available=%d MB, native reserve=%d MB, physical cap=%d MB", availableMB, reserveMB, physicalBasedMB);
        } else {
            allocmem = physicalBasedMB;
            NSLog(@"[EnhancedMemory] os_proc_available_memory unavailable; using physical-memory fallback");
        }
        allocmem = MAX(384, allocmem);
    } else {
        allocmem = getPrefInt(@"java.allocated_memory");
    }
    NSLog(@"[JavaLauncher] Max RAM allocation is set to %d MB", allocmem);
'''
require(old_ram in java or "[EnhancedMemory]" in java, "Auto RAM block no longer matches expected upstream code")
java = java.replace(old_ram, new_ram, 1)

# In upstream, Auto resolves to ANGLE for modern Minecraft. The Enhanced build
# uses the renderer we are actively optimizing and testing (MobileGlues 2.0).
old_auto = '''        if (!strcmp(glLibName, "auto")) {
            // workaround only applies to 1.20.2+
            glLibName = RENDERER_NAME_MTL_ANGLE;
        }
'''
new_auto = '''        if (!strcmp(glLibName, "auto")) {
            // Enhanced v2 performance baseline: MobileGlues 2.x is the modern
            // OpenGL translation path optimized for Minecraft draw workloads.
            glLibName = RENDERER_NAME_MOBILEGLUES;
            NSLog(@"[EnhancedRenderer] Auto -> MobileGlues");
        }
'''
require(old_auto in java or "[EnhancedRenderer]" in java, "Auto renderer block no longer matches expected upstream code")
java = java.replace(old_auto, new_auto, 1)
JAVA_LAUNCHER.write_text(java, encoding="utf-8")

# Brand the test build while keeping the original bundle identifier so the
# user's existing Amethyst data/profile layout remains compatible.
with INFO_PLIST.open("rb") as fh:
    plist = plistlib.load(fh)
plist["CFBundleDisplayName"] = "Amethyst Enhanced v2"
plist["CFBundleName"] = "AmethystEnhancedV2"
with INFO_PLIST.open("wb") as fh:
    plistlib.dump(plist, fh, sort_keys=False)

print("Prepared Amethyst Enhanced v2 build:")
print("  - MobileGlues 2.x source layout + Release/ThinLTO path")
print(f"  - native A13 codegen target: {CPU_TARGET}")
print("  - headroom-aware iOS Auto RAM policy")
print("  - Auto renderer -> MobileGlues")
print("  - obsolete dynamic SPIRV-Cross copy removed")
print("  - display name set to Amethyst Enhanced v2")
