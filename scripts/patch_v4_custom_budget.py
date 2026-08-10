#!/usr/bin/env python3
"""Wire Smart->Custom transitions and the device-budget safety meter.

This patch is intentionally advisory. Manual settings are never blocked: when a
user diverges from the last Smart baseline, the launcher marks the configuration
Custom, visualizes pressure against that device's conservative envelope, and
warns only when crossing high-risk bands. The user can keep the override.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PREFS = ROOT / "Natives" / "PLPreferences.m"
UI = ROOT / "Natives" / "LauncherPreferencesViewController.m"
SMART = ROOT / "Natives" / "EnhancedSmartSettings.m"
CMAKE = ROOT / "Natives" / "CMakeLists.txt"


def require(cond, msg):
    if not cond:
        raise SystemExit(f"patch_v4_custom_budget: {msg}")


def patch_once(path: Path, old: str, new: str, marker: str, label: str):
    text = path.read_text(encoding="utf-8")
    if marker in text:
        print(f"{label} already applied")
        return
    require(old in text, f"anchor missing for {label}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"Patched {label}")


# Persist the exact Smart baseline so Custom mode is reversible and the pressure
# meter compares against settings actually derived for this hardware, not a
# generic device-name table.
patch_once(
    PREFS,
    '''            @"smart_settings_fingerprint": @"",\n            @"smart_settings_summary": @"",\n            @"smart_settings_logic_version": @(0)\n''',
    '''            @"smart_settings_fingerprint": @"",\n            @"smart_settings_summary": @"",\n            @"smart_settings_logic_version": @(0),\n            @"smart_settings_mode": @"smart",\n            @"smart_settings_baseline": @{}\n''',
    '@"smart_settings_baseline": @{}',
    "Smart baseline state",
)

# Store baseline + reset Custom state whenever a deliberate Smart scan applies.
patch_once(
    SMART,
    '#import "LauncherPreferences.h"\n',
    '#import "LauncherPreferences.h"\n#import "EnhancedDeviceBudget.h"\n',
    '#import "EnhancedDeviceBudget.h"',
    "device budget import",
)

baseline_anchor = '''    setPrefObject(@"internal.smart_settings_logic_version", @(kEnhancedSmartSettingsLogicVersion));\n\n    NSLog(@"[SmartSettings] device=%@ iOS=%@ RAM=%.2fGB cpu=%ld metalTier=%ld metal=%@ maxBuffer=%lluMB nativePixels=%.0f maxFPS=%ld thermal=%ld lowPower=%@",\n'''
baseline_block = '''    setPrefObject(@"internal.smart_settings_logic_version", @(kEnhancedSmartSettingsLogicVersion));\n    NSDictionary *smartBaseline = @{\n        @"video.renderer": r[@"renderer"],\n        @"video.performance_profile": r[@"profile"],\n        @"video.resolution": r[@"resolution"],\n        @"video.max_framerate": r[@"maxFramerate"],\n        @"video.thermal_governor": r[@"thermalGovernor"],\n        @"video.shader_cache": r[@"shaderCache"],\n        @"video.zink_descriptors": r[@"zinkDescriptors"],\n        @"video.mvk_argument_buffers": r[@"mvkArgumentBuffers"],\n        @"java.auto_ram": r[@"autoRAM"]\n    };\n    setPrefObject(@"internal.smart_settings_baseline", smartBaseline);\n    [EnhancedDeviceBudget markSmartBaselineApplied];\n\n    NSLog(@"[SmartSettings] device=%@ iOS=%@ RAM=%.2fGB cpu=%ld metalTier=%ld metal=%@ maxBuffer=%lluMB nativePixels=%.0f maxFPS=%ld thermal=%ld lowPower=%@",\n'''
patch_once(
    SMART,
    baseline_anchor,
    baseline_block,
    'NSDictionary *smartBaseline = @{',
    "Smart baseline persistence",
)

# Do not silently overwrite a user's Custom setup after an OS/fingerprint change.
# Manual Scan remains available and is the explicit opt-in to replace Custom.
skip_anchor = '''    NSString *oldFingerprint = getPrefObject(@"internal.smart_settings_fingerprint");\n    if (!force && oldFingerprint.length && [oldFingerprint isEqualToString:newFingerprint]) {\n        if (completion) completion();\n        return;\n    }\n\n    UIViewController *host = [self topPresenter:presenter];\n'''
skip_block = '''    NSString *oldFingerprint = getPrefObject(@"internal.smart_settings_fingerprint");\n    if (!force && oldFingerprint.length && [oldFingerprint isEqualToString:newFingerprint]) {\n        if (completion) completion();\n        return;\n    }\n    NSString *smartMode = getPrefObject(@"internal.smart_settings_mode");\n    if (!force && oldFingerprint.length && [smartMode isEqualToString:@"custom"]) {\n        NSLog(@"[SmartSettings] fingerprint changed but Custom mode is active; preserving manual overrides until explicit rescan");\n        if (completion) completion();\n        return;\n    }\n\n    UIViewController *host = [self topPresenter:presenter];\n'''
patch_once(
    SMART,
    skip_anchor,
    skip_block,
    'fingerprint changed but Custom mode is active',
    "Custom override preservation",
)

# Settings UI: monitor every performance-sensitive user write, keep the meter
# visible, and allow the user to go beyond the envelope after an advisory alert.
patch_once(
    UI,
    '#import "EnhancedSmartSettings.h"\n',
    '#import "EnhancedSmartSettings.h"\n#import "EnhancedDeviceBudget.h"\n',
    '#import "EnhancedDeviceBudget.h"',
    "device budget UI import",
)

setpref_old = '''    self.setPreference = ^(NSString *section, NSString *key, id value){\n        NSString *keyFull = [NSString stringWithFormat:@"%@.%@", section, key];\n        setPrefObject(keyFull, value);\n    };\n'''
setpref_new = '''    __weak typeof(self) weakSelf = self;\n    self.setPreference = ^(NSString *section, NSString *key, id value){\n        NSString *keyFull = [NSString stringWithFormat:@"%@.%@", section, key];\n        setPrefObject(keyFull, value);\n        typeof(self) strongSelf = weakSelf;\n        if (strongSelf) {\n            [EnhancedDeviceBudget userDidChangePreference:keyFull value:value presenter:strongSelf];\n            [EnhancedDeviceBudget refreshBudgetHeader:strongSelf.tableView.tableHeaderView];\n        }\n    };\n'''
patch_once(
    UI,
    setpref_old,
    setpref_new,
    '__weak typeof(self) weakSelf = self;',
    "Custom mode preference interception",
)

header_old = '''    [super viewDidLoad];\n    if (self.navigationController == nil) {\n'''
header_new = '''    [super viewDidLoad];\n    self.tableView.tableHeaderView = [EnhancedDeviceBudget budgetHeaderViewForWidth:self.tableView.bounds.size.width];\n    if (self.navigationController == nil) {\n'''
patch_once(
    UI,
    header_old,
    header_new,
    'budgetHeaderViewForWidth:self.tableView.bounds.size.width',
    "device budget meter header",
)

# Refresh after returning from a picker/child pane or after Smart rescan.
view_anchor = '''- (void)viewWillDisappear:(BOOL)animated {\n'''
view_block = '''- (void)viewWillAppear:(BOOL)animated {\n    [super viewWillAppear:animated];\n    UIView *header = self.tableView.tableHeaderView;\n    CGFloat width = self.tableView.bounds.size.width;\n    if (![header.accessibilityIdentifier isEqualToString:@"EnhancedDeviceBudgetHeader"] || ABS(header.bounds.size.width - width) > 1.0) {\n        self.tableView.tableHeaderView = [EnhancedDeviceBudget budgetHeaderViewForWidth:width];\n    } else {\n        [EnhancedDeviceBudget refreshBudgetHeader:header];\n    }\n}\n\n- (void)viewWillDisappear:(BOOL)animated {\n'''
patch_once(
    UI,
    view_anchor,
    view_block,
    'ABS(header.bounds.size.width - width)',
    "budget meter lifecycle refresh",
)

# Compile the helper. EnhancedSmartSettings.m was already added by the preceding
# Smart Settings patch, so place this next to it deterministically.
patch_once(
    CMAKE,
    '  EnhancedSmartSettings.m\n',
    '  EnhancedSmartSettings.m\n  EnhancedDeviceBudget.m\n',
    '  EnhancedDeviceBudget.m\n',
    "device budget native source",
)

print("Applied Enhanced v4 Custom Smart mode + device budget safety meter")
