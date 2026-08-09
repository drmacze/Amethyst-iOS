#!/usr/bin/env python3
from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parents[1]
UTILS = ROOT / "Natives" / "utils.h"
PREFS = ROOT / "Natives" / "LauncherPreferences.m"
JAVA = ROOT / "Natives" / "JavaLauncher.m"
PLIST = ROOT / "Natives" / "Info.plist"
CMAKE = ROOT / "Natives" / "CMakeLists.txt"


def require(cond, msg):
    if not cond:
        raise SystemExit(f"patch_v4_graphics: {msg}")

# Add a separate modern Zink entry so the known-working legacy Mesa binary remains
# available for recovery. The modern binary is produced by v4 CI.
u = UTILS.read_text()
old = '#define RENDERER_NAME_VK_ZINK "libOSMesa.8.dylib"\n'
new = old + '#define RENDERER_NAME_VK_ZINK_MODERN "libOSMesaModern.8.dylib"\n'
require(old in u or 'RENDERER_NAME_VK_ZINK_MODERN' in u, 'Zink renderer constant missing')
if 'RENDERER_NAME_VK_ZINK_MODERN' not in u:
    u = u.replace(old, new, 1)
UTILS.write_text(u)

p = PREFS.read_text()
old_keys = '''        @ RENDERER_NAME_MOBILEGLUES,\n        @ RENDERER_NAME_VK_ZINK\n'''
new_keys = '''        @ RENDERER_NAME_MOBILEGLUES,\n        @ RENDERER_NAME_VK_ZINK_MODERN,\n        @ RENDERER_NAME_VK_ZINK\n'''
require(old_keys in p or 'RENDERER_NAME_VK_ZINK_MODERN' in p, 'renderer key list changed')
if 'RENDERER_NAME_VK_ZINK_MODERN' not in p:
    p = p.replace(old_keys, new_keys, 1)

old_names = '''        localize(@"preference.title.renderer.debug.mg", nil),\n        localize(@"preference.title.renderer.debug.zink", nil)\n'''
new_names = '''        localize(@"preference.title.renderer.debug.mg", nil),\n        @"Zink Modern — Mesa 26.1.6 / MoltenVK 1.4.2",\n        @"Zink Legacy — Mesa 21 recovery"\n'''
require(old_names in p or 'Zink Modern' in p, 'renderer name list changed')
if 'Zink Modern' not in p:
    p = p.replace(old_names, new_names, 1)
PREFS.write_text(p)

j = JAVA.read_text()
# This block runs after the renderer has been resolved by the existing v3 build patch.
# Keep Auto on the proven MobileGlues baseline; Modern Zink is explicit until real A13
# on-device validation proves it is safer as an automatic choice.
anchor = '''    // Preset OpenGL libname\n    const char *glLibName = getenv("POJAV_RENDERER");\n'''
block = '''    // Enhanced v4: isolate Mesa/Zink caches from MobileGlues and from older\n    // Mesa builds. Never force experimental descriptor modes; Mesa's own `auto`\n    // selector is capability-aware and is the safest default before device data.\n    const char *selectedRendererV4 = getenv("POJAV_RENDERER");\n    if (selectedRendererV4 && !strcmp(selectedRendererV4, RENDERER_NAME_VK_ZINK_MODERN)) {\n        NSString *mesaCache = [NSString stringWithFormat:@"%s/.amethyst/mesa/26.1.6", getenv("POJAV_HOME")];\n        [fm createDirectoryAtPath:mesaCache withIntermediateDirectories:YES attributes:nil error:nil];\n        setenv("MESA_SHADER_CACHE_DIR", mesaCache.UTF8String, 1);\n        setenv("MESA_DISK_CACHE_SINGLE_FILE", "1", 1);\n        setenv("GALLIUM_DRIVER", "zink", 1);\n        setenv("ZINK_DESCRIPTORS", "auto", 1);\n        NSLog(@"[EnhancedGraphics] Zink Modern selected; Mesa cache=%@", mesaCache);\n    }\n\n'''
if '[EnhancedGraphics] Zink Modern selected' not in j:
    require(anchor in j, 'OpenGL library anchor missing')
    j = j.replace(anchor, block + anchor, 1)

# Make version/runtime decisions visible in the log, especially for 26.x where
# LWJGL/JNA requirements have changed substantially.
launch_anchor = '    NSLog(@"[JavaLauncher] Looking for Java %d or later", minVersion);\n'
version_log = '''    NSLog(@"[EnhancedRuntime] requestedMinecraft=%@ minimumJava=%d",\n          PLProfiles.current.selectedProfile[@"lastVersionId"] ?: @"unknown", minVersion);\n'''
if '[EnhancedRuntime] requestedMinecraft=' not in j:
    require(launch_anchor in j, 'Java selection anchor missing')
    j = j.replace(launch_anchor, version_log + launch_anchor, 1)
JAVA.write_text(j)

# Ensure the new cache manager source remains in the actual native target even if
# upstream CMake moves around in a future rebase.
c = CMAKE.read_text()
if 'EnhancedCacheManager.m' not in c:
    needle = '  ContentHubViewController.m\n'
    require(needle in c, 'CMake launcher source anchor missing')
    c = c.replace(needle, needle + '  EnhancedCacheManager.m\n', 1)
CMAKE.write_text(c)

with PLIST.open('rb') as f:
    pl = plistlib.load(f)
pl['CFBundleDisplayName'] = 'Amethyst Enhanced v4'
pl['CFBundleName'] = 'AmethystEnhancedV4'
with PLIST.open('wb') as f:
    plistlib.dump(pl, f, sort_keys=False)

print('Applied Enhanced v4 graphics/runtime integration')
