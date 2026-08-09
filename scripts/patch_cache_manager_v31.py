#!/usr/bin/env python3
"""Wire the v3.1 safe cache manager into the Enhanced launcher build."""

from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parents[1]
CMAKE = ROOT / "Natives" / "CMakeLists.txt"
MENU = ROOT / "Natives" / "LauncherMenuViewController.m"
JAVA = ROOT / "Natives" / "JavaLauncher.m"
INFO = ROOT / "Natives" / "Info.plist"


def require(cond: bool, message: str) -> None:
    if not cond:
        raise SystemExit(f"patch_cache_manager_v31: {message}")


# Compile the cache manager as part of the main executable.
cmake = CMAKE.read_text(encoding="utf-8")
if "  EnhancedCacheManager.m\n" not in cmake:
    anchor = "  ContentHubViewController.m\n"
    require(anchor in cmake, "CMake ContentHub source anchor missing")
    cmake = cmake.replace(anchor, anchor + "  EnhancedCacheManager.m\n", 1)
CMAKE.write_text(cmake, encoding="utf-8")

# Add a first-class Clear Cache entry to the launcher sidebar. The manager itself
# decides which files are safe: user worlds, mods, packs, shaders and profiles are
# never part of the deletion set.
menu = MENU.read_text(encoding="utf-8")
if '#import "EnhancedCacheManager.h"\n' not in menu:
    anchor = '#import "ALTServerConnection.h"\n'
    require(anchor in menu, "LauncherMenu import anchor missing")
    menu = menu.replace(anchor, anchor + '#import "EnhancedCacheManager.h"\n', 1)

if 'title:@"Clear Cache"' not in menu:
    anchor = '''    [self.options addObject:\n     (id)[LauncherMenuCustomItem\n          title:localize(@"launcher.menu.execute_jar", nil)\n          imageName:@"MenuInstallJar" action:^{\n        [contentNavigationController performSelector:@selector(enterModInstaller)];\n    }]];\n'''
    require(anchor in menu, "LauncherMenu execute-jar block missing")
    addition = anchor + '''\n    [self.options addObject:\n     (id)[LauncherMenuCustomItem\n          title:@"Clear Cache"\n          imageName:@"trash.circle" action:^{\n        [EnhancedCacheManager presentClearCacheFromViewController:self];\n    }]];\n'''
    menu = menu.replace(anchor, addition, 1)
MENU.write_text(menu, encoding="utf-8")

# Renderer cache can still exist in MobileGlues' in-memory singleton after the
# user returns from Minecraft. The UI therefore writes a reset marker and this
# hook performs the deletion again before the renderer is loaded on a later cold
# launch. That makes the reset deterministic instead of relying on whether the
# dylib happened to be unloaded.
java = JAVA.read_text(encoding="utf-8")
if '#import "EnhancedCacheManager.h"\n' not in java:
    anchor = '#import "JavaLauncher.h"\n'
    require(anchor in java, "JavaLauncher import anchor missing")
    java = java.replace(anchor, '#import "EnhancedCacheManager.h"\n' + anchor, 1)

if "[EnhancedCacheManager performPendingRendererCacheCleanup];" not in java:
    anchor = '''    NSLog(@"[JavaLauncher] Beginning JVM launch");\n'''
    require(anchor in java, "JavaLauncher launch anchor missing")
    java = java.replace(anchor, anchor + "    [EnhancedCacheManager performPendingRendererCacheCleanup];\n", 1)
JAVA.write_text(java, encoding="utf-8")

# Distinguish this user-facing maintenance build from the original v3 artifact.
with INFO.open("rb") as fh:
    plist = plistlib.load(fh)
plist["CFBundleDisplayName"] = "Amethyst Enhanced v3.1"
plist["CFBundleName"] = "AmethystEnhancedV31"
with INFO.open("wb") as fh:
    plistlib.dump(plist, fh, sort_keys=False)

print("Applied Amethyst Enhanced v3.1 cache-manager integration:")
print("  - Clear Cache launcher entry")
print("  - renderer cache size/clear + cold-launch reset marker")
print("  - launcher/network cache size/clear")
print("  - safe all-cache clear; user Minecraft content excluded")
print("  - display name set to Amethyst Enhanced v3.1")
