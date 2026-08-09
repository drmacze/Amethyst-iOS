#!/usr/bin/env python3
"""Prepare the Amethyst Enhanced v3 CI build.

v3 keeps the rebasing-friendly build-time patch model from v2, but shifts the
priority toward sustained A13 performance and repeat-launch behaviour:
MobileGlues 2.x Release/ThinLTO + A13 codegen, headroom-aware Auto RAM, a
launcher-writable/versioned MobileGlues state directory so the GLSL cache can
persist safely across profiles on iOS, and MobileGlues as the Enhanced Auto
renderer.
"""

from pathlib import Path
import os
import plistlib

ROOT = Path(__file__).resolve().parents[1]
MAKEFILE = ROOT / "Makefile"
INFO_PLIST = ROOT / "Natives" / "Info.plist"
CMAKE = ROOT / "Natives" / "CMakeLists.txt"
JAVA_LAUNCHER = ROOT / "Natives" / "JavaLauncher.m"
CONTENT_HUB = ROOT / "Natives" / "ContentHubViewController.m"
CPU_TARGET = os.environ.get("AMETHYST_CPU_TARGET", "apple-a13").strip() or "apple-a13"
MG_STATE_VERSION = "2.0.0"


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

# The native Amethyst target exposes AMETHYST_CPU_TARGET in Enhanced CMakeLists.
cmake = CMAKE.read_text(encoding="utf-8")
needle = 'set(AMETHYST_CPU_TARGET "apple-a8")'
replacement = f'set(AMETHYST_CPU_TARGET "{CPU_TARGET}")'
require(needle in cmake or replacement in cmake, "AMETHYST_CPU_TARGET hook missing from CMakeLists")
cmake = cmake.replace(needle, replacement, 1)
CMAKE.write_text(cmake, encoding="utf-8")

java = JAVA_LAUNCHER.read_text(encoding="utf-8")

# os_proc_available_memory() exposes current per-process allocation headroom.
if "#include <os/proc.h>" not in java:
    include_anchor = "#include <unistd.h>\n"
    require(include_anchor in java, "JavaLauncher include anchor missing")
    java = java.replace(include_anchor, include_anchor + "#include <os/proc.h>\n", 1)

# Replace fixed-percent Auto RAM with an app-limit-aware cap. Keep the physical
# RAM ratio as an upper bound, but reserve native/rendering headroom instead of
# handing nearly all available process memory to the Java heap.
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
            // Keep a dynamic native reserve. Metal/MobileGlues, LWJGL, JIT code,
            // JVM native allocations and shader caches all live outside -Xmx.
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

# MobileGlues defaults its state directory to /sdcard/MG. That is an Android
# path and is not writable inside a normal iOS sandbox. Give Enhanced a stable,
# launcher-global state directory under POJAV_HOME instead. A global renderer
# cache is intentional: translated shader output is keyed by source and can be
# reused by multiple profiles using the same pinned renderer, while a profile
# switch in the same launcher process must not leave MG_DIR_PATH pointing at the
# first profile. The directory is versioned because the cache file itself has no
# translator-version header. Respect an explicit user MG_DIR_PATH override.
mg_anchor = '''    NSLog(@"[JavaLauncher] Looking for Java %d or later", minVersion);
'''
mg_block = f'''    const char *existingMGDir = getenv("MG_DIR_PATH");
    if (existingMGDir == NULL || existingMGDir[0] == '\\0') {{
        const char *pojavHomeC = getenv("POJAV_HOME");
        NSString *pojavHome = pojavHomeC ? @(pojavHomeC) : gameDir;
        NSString *mgDir = [[[pojavHome stringByAppendingPathComponent:@".amethyst"]
            stringByAppendingPathComponent:@"mobileglues"] stringByAppendingPathComponent:@"{MG_STATE_VERSION}"];
        NSError *mgDirError = nil;
        if ([fm createDirectoryAtPath:mgDir withIntermediateDirectories:YES attributes:nil error:&mgDirError]) {{
            setenv("MG_DIR_PATH", mgDir.UTF8String, 1);
            NSString *cachePath = [mgDir stringByAppendingPathComponent:@"glsl_cache.tmp"];
            NSDictionary *cacheAttrs = [fm attributesOfItemAtPath:cachePath error:nil];
            unsigned long long cacheBytes = [cacheAttrs[NSFileSize] unsignedLongLongValue];
            NSLog(@"[EnhancedRenderer] MobileGlues data=%@, GLSL cache=%llu KB", mgDir, cacheBytes >> 10);
        }} else {{
            NSLog(@"[EnhancedRenderer] Could not create MobileGlues state directory %@: %@", mgDir, mgDirError.localizedDescription);
        }}
    }} else {{
        NSLog(@"[EnhancedRenderer] Respecting existing MG_DIR_PATH=%s", existingMGDir);
    }}

'''
if "[EnhancedRenderer] MobileGlues data=" not in java:
    require(mg_anchor in java, "Java runtime lookup anchor missing for MobileGlues state path")
    java = java.replace(mg_anchor, mg_block + mg_anchor, 1)

# In upstream, Auto resolves to ANGLE for modern Minecraft. Enhanced uses the
# renderer we are optimizing and testing: MobileGlues 2.0.
old_auto = '''        if (!strcmp(glLibName, "auto")) {
            // workaround only applies to 1.20.2+
            glLibName = RENDERER_NAME_MTL_ANGLE;
        }
'''
new_auto = '''        if (!strcmp(glLibName, "auto")) {
            // Enhanced v3 sustained-performance baseline: MobileGlues 2.x.
            glLibName = RENDERER_NAME_MOBILEGLUES;
            NSLog(@"[EnhancedRenderer] Auto -> MobileGlues");
        }
'''
require(old_auto in java or "[EnhancedRenderer] Auto -> MobileGlues" in java, "Auto renderer block no longer matches expected upstream code")
java = java.replace(old_auto, new_auto, 1)

# Capture system conditions in the same log used for renderer/memory A/B tests.
launch_anchor = '''    NSLog(@"[JavaLauncher] Beginning JVM launch");
'''
perf_log = '''    NSLog(@"[JavaLauncher] Beginning JVM launch");
    if (@available(iOS 11.0, *)) {
        NSLog(@"[EnhancedPerf] thermalState=%ld lowPowerMode=%@",
              (long)NSProcessInfo.processInfo.thermalState,
              NSProcessInfo.processInfo.lowPowerModeEnabled ? @"YES" : @"NO");
    }
'''
if "[EnhancedPerf] thermalState=" not in java:
    require(launch_anchor in java, "JVM launch log anchor missing")
    java = java.replace(launch_anchor, perf_log, 1)

JAVA_LAUNCHER.write_text(java, encoding="utf-8")

# Content Hub's ZIP enumeration callback writes through NSError** several times.
# Under ARC, an outer local captured by a nested block is const by default.
hub = CONTENT_HUB.read_text(encoding="utf-8")
world_method = '- (void)installWorldArchive:(NSString *)archivePath item:(NSDictionary *)item version:(NSDictionary *)version {'
require(world_method in hub, "Content Hub world installer method missing")
method_pos = hub.index(world_method)
error_pos = hub.find("        NSError *error = nil;", method_pos)
require(error_pos != -1 or "        __block NSError *error = nil;" in hub[method_pos:method_pos + 500], "Content Hub world installer NSError declaration missing")
if error_pos != -1 and "        __block NSError *error = nil;" not in hub[method_pos:error_pos + 80]:
    hub = hub[:error_pos] + hub[error_pos:].replace(
        "        NSError *error = nil;",
        "        __block NSError *error = nil;",
        1,
    )
CONTENT_HUB.write_text(hub, encoding="utf-8")

# Brand the test build while keeping the original bundle identifier/data layout
# so an install over v2 keeps profiles, worlds, controls and launcher settings.
with INFO_PLIST.open("rb") as fh:
    plist = plistlib.load(fh)
plist["CFBundleDisplayName"] = "Amethyst Enhanced v3"
plist["CFBundleName"] = "AmethystEnhancedV3"
with INFO_PLIST.open("wb") as fh:
    plistlib.dump(plist, fh, sort_keys=False)

print("Prepared Amethyst Enhanced v3 build:")
print("  - MobileGlues 2.x Release/ThinLTO + AppleClang -O3 path")
print(f"  - native A13 codegen target: {CPU_TARGET}")
print("  - headroom-aware iOS Auto RAM policy")
print(f"  - launcher-global/versioned MobileGlues state + persistent GLSL cache ({MG_STATE_VERSION})")
print("  - Auto renderer -> MobileGlues")
print("  - thermal / Low Power Mode launch diagnostics")
print("  - Content Hub ARC-safe world extraction")
print("  - obsolete dynamic SPIRV-Cross copy removed")
print("  - display name set to Amethyst Enhanced v3")
