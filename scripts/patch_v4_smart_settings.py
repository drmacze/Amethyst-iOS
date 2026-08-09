#!/usr/bin/env python3
"""Wire Enhanced v4 Smart Settings into the launcher.

The recommendation engine itself lives in Natives/EnhancedSmartSettings.m so it
can be tested and evolved independently. This build-time patch only adds stable
preference keys, UI entry points, first-run invocation, and native linking.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PREFS = ROOT / "Natives" / "PLPreferences.m"
UI = ROOT / "Natives" / "LauncherPreferencesViewController.m"
SCENE = ROOT / "Natives" / "SceneDelegate.m"
CMAKE = ROOT / "Natives" / "CMakeLists.txt"


def require(cond, msg):
    if not cond:
        raise SystemExit(f"patch_v4_smart_settings: {msg}")


def patch_once(path: Path, old: str, new: str, marker: str, label: str):
    text = path.read_text(encoding="utf-8")
    if marker in text:
        print(f"{label} already applied")
        return
    require(old in text, f"anchor missing for {label}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"Patched {label}")


# Smart Settings is enabled by default, but remains user-disableable. Device
# fingerprint state is stored in internal preferences so the full visible scan
# only reruns when hardware/OS/tuning logic changes or the user asks for it.
patch_once(
    PREFS,
    '''            @"performance_profile": @"balanced",\n            @"thermal_governor": @YES,\n''',
    '''            @"performance_profile": @"balanced",\n            @"smart_settings": @YES,\n            @"thermal_governor": @YES,\n''',
    '@"smart_settings": @YES',
    "Smart Settings default",
)

patch_once(
    PREFS,
    '''        @"internal": @{\n            @"isolated": @NO,\n            @"latest_version": [NSDictionary new]\n        }.mutableCopy\n''',
    '''        @"internal": @{\n            @"isolated": @NO,\n            @"latest_version": [NSDictionary new],\n            @"smart_settings_fingerprint": @"",\n            @"smart_settings_summary": @"",\n            @"smart_settings_logic_version": @(0)\n        }.mutableCopy\n''',
    '@"smart_settings_fingerprint": @""',
    "Smart Settings scan state",
)

# Import the engine and add an enable switch plus explicit rescan action directly
# beside the v4 performance profile. Manual controls remain available below it.
patch_once(
    UI,
    '#import "LauncherPreferencesViewController.h"\n',
    '#import "LauncherPreferencesViewController.h"\n#import "EnhancedSmartSettings.h"\n',
    '#import "EnhancedSmartSettings.h"',
    "Smart Settings UI import",
)

profile_ui = '''            @{@"key": @"performance_profile",\n              @"title": @"Enhanced Performance Profile",\n              @"hasDetail": @YES,\n              @"icon": @"gauge.with.dots.needle.67percent",\n              @"type": self.typePickField,\n              @"enableCondition": whenNotInGame,\n              @"pickKeys": @[@"compatibility", @"balanced", @"performance", @"max"],\n              @"pickList": @[@"Compatibility", @"Balanced (Recommended)", @"Performance", @"Max Performance"]\n            },\n'''
smart_ui = profile_ui + '''            @{@"key": @"smart_settings",\n              @"title": @"Smart Settings Auto Optimization",\n              @"hasDetail": @YES,\n              @"icon": @"wand.and.stars",\n              @"type": self.typeSwitch,\n              @"enableCondition": whenNotInGame\n            },\n            @{@"key": @"smart_settings_scan",\n              @"title": @"Scan Device & Apply Best Settings",\n              @"hasDetail": @YES,\n              @"icon": @"iphone.gen3.radiowaves.left.and.right",\n              @"type": self.typeButton,\n              @"enableCondition": whenNotInGame,\n              @"action": ^void(){\n                  [EnhancedSmartSettings presentScanFrom:self force:YES completion:^{\n                      [self.tableView reloadData];\n                  }];\n              }\n            },\n'''
patch_once(
    UI,
    profile_ui,
    smart_ui,
    '@"key": @"smart_settings_scan"',
    "Smart Settings controls",
)

# Automatically scan after the launcher is visible. The engine itself waits for
# preferences and skips the expensive/visible scan when its fingerprint matches.
patch_once(
    SCENE,
    '#import "utils.h"\n',
    '#import "utils.h"\n#import "EnhancedSmartSettings.h"\n',
    '#import "EnhancedSmartSettings.h"',
    "Smart Settings scene import",
)
patch_once(
    SCENE,
    '''    launchInitialViewController(self.window);\n    [self.window makeKeyAndVisible];\n''',
    '''    launchInitialViewController(self.window);\n    [self.window makeKeyAndVisible];\n    [EnhancedSmartSettings runAutomaticScanIfNeededFrom:self.window.rootViewController];\n''',
    'runAutomaticScanIfNeededFrom:self.window.rootViewController',
    "first-run Smart Settings scan",
)

# Compile the engine into the native launcher and link the public Metal framework
# used only for capability probing. No private Apple framework/API is required.
patch_once(
    CMAKE,
    '  ContentHubViewController.m\n',
    '  ContentHubViewController.m\n  EnhancedSmartSettings.m\n',
    '  EnhancedSmartSettings.m\n',
    "Smart Settings native source",
)
patch_once(
    CMAKE,
    '  "-framework IOKit"\n  "-framework QuartzCore"\n',
    '  "-framework IOKit"\n  "-framework Metal"\n  "-framework QuartzCore"\n',
    '  "-framework Metal"\n',
    "Metal capability framework",
)

print("Applied Enhanced v4 Smart Settings integration")
