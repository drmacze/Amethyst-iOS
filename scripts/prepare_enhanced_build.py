#!/usr/bin/env python3
"""Prepare the Amethyst Enhanced CI build.

This script intentionally changes only the CI working tree. It keeps upstream
Amethyst source easy to rebase while adapting the build to the pinned
MobileGlues 2.x layout and forcing optimized native builds.
"""

from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parents[1]
MAKEFILE = ROOT / "Makefile"
INFO_PLIST = ROOT / "Natives" / "Info.plist"


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
# its non-Debug IPO/ThinLTO path when supported.
if "-DCMAKE_BUILD_TYPE=Release" not in dep:
    needle = "\t\t-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \\\n"
    require(needle in dep, "could not locate MobileGlues CMake deployment-target line")
    dep = dep.replace(
        needle,
        needle + "\t\t-DCMAKE_BUILD_TYPE=Release \\\n",
        1,
    )

dep = dep.replace(
    "cmake --build $(WORKINGDIR)/mobileglues --config RelWithDebInfo",
    "cmake --build $(WORKINGDIR)/mobileglues --config Release",
)

# MobileGlues 2.x has SPIRV_CROSS_STATIC=ON; the old standalone dylib path no
# longer exists and should not be packaged.
dep_lines = [
    line for line in dep.splitlines()
    if "libspirv-cross-c-shared.0.dylib" not in line
]
text = head + "dep_mg:" + "\n".join(dep_lines)
if not text.endswith("\n"):
    text += "\n"
MAKEFILE.write_text(text, encoding="utf-8")

# Brand the test build while keeping the original bundle identifier so the
# user's existing Amethyst data/profile layout remains compatible.
with INFO_PLIST.open("rb") as fh:
    plist = plistlib.load(fh)
plist["CFBundleDisplayName"] = "Amethyst Enhanced"
plist["CFBundleName"] = "AmethystEnhanced"
with INFO_PLIST.open("wb") as fh:
    plistlib.dump(plist, fh, sort_keys=False)

print("Prepared Amethyst Enhanced build:")
print("  - MobileGlues 2.x source layout")
print("  - MobileGlues Release configuration")
print("  - obsolete dynamic SPIRV-Cross copy removed")
print("  - display name set to Amethyst Enhanced")
