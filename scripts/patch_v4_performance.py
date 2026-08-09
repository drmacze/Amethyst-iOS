#!/usr/bin/env python3
"""Enhanced v4 performance/compatibility policy.

This patch deliberately exposes only knobs backed by public Apple APIs or
upstream Mesa/MoltenVK configuration. It does not attempt private iOS clock,
thermal, scheduler or GPU-frequency overrides.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PREFS = ROOT / "Natives" / "PLPreferences.m"
UI = ROOT / "Natives" / "LauncherPreferencesViewController.m"
JAVA = ROOT / "Natives" / "JavaLauncher.m"


def require(cond, msg):
    if not cond:
        raise SystemExit(f"patch_v4_performance: {msg}")


def replace_once(path: Path, old: str, new: str, marker: str, label: str):
    text = path.read_text(encoding="utf-8")
    if marker in text:
        print(f"{label} already applied")
        return
    require(old in text, f"anchor missing for {label}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"Patched {label}")


# Isolatable per-instance defaults: profiles can be tuned per Minecraft/modpack.
replace_once(
    PREFS,
    '''            @"performance_hud": @NO,\n            @"fullscreen_airplay": @YES,\n''',
    '''            @"performance_hud": @NO,\n            // Enhanced v4 public-API performance policy. Balanced + adaptive is\n            // intentionally the default; Max never bypasses iOS thermal limits.\n            @"performance_profile": @"balanced",\n            @"thermal_governor": @YES,\n            @"shader_cache": @YES,\n            @"zink_descriptors": @"auto",\n            @"mvk_argument_buffers": @"auto",\n            @"fullscreen_airplay": @YES,\n''',
    '@"performance_profile": @"balanced"',
    "performance defaults",
)


# Put advanced controls directly below renderer selection. Literal labels avoid
# coupling this experimental branch to upstream localization files while keeping
# every option visible and reversible.
renderer_ui = '''            @{@"key": @"renderer",\n              @"hasDetail": @YES,\n              @"icon": @"cpu",\n              @"type": self.typePickField,\n              @"enableCondition": whenNotInGame,\n              @"pickKeys": self.rendererKeys,\n              @"pickList": self.rendererList\n            },\n'''
advanced_ui = renderer_ui + '''            @{@"key": @"performance_profile",\n              @"title": @"Enhanced Performance Profile",\n              @"hasDetail": @YES,\n              @"icon": @"gauge.with.dots.needle.67percent",\n              @"type": self.typePickField,\n              @"enableCondition": whenNotInGame,\n              @"pickKeys": @[@"compatibility", @"balanced", @"performance", @"max"],\n              @"pickList": @[@"Compatibility", @"Balanced (Recommended)", @"Performance", @"Max Performance"]\n            },\n            @{@"key": @"thermal_governor",\n              @"title": @"Adaptive Thermal Guard",\n              @"hasDetail": @YES,\n              @"icon": @"thermometer.medium",\n              @"type": self.typeSwitch,\n              @"enableCondition": whenNotInGame\n            },\n            @{@"key": @"shader_cache",\n              @"title": @"Mesa Shader Cache",\n              @"hasDetail": @YES,\n              @"icon": @"externaldrive.badge.checkmark",\n              @"type": self.typeSwitch,\n              @"enableCondition": whenNotInGame\n            },\n            @{@"key": @"zink_descriptors",\n              @"title": @"Zink Descriptor Manager",\n              @"hasDetail": @YES,\n              @"icon": @"rectangle.3.group",\n              @"type": self.typePickField,\n              @"enableCondition": whenNotInGame,\n              @"pickKeys": @[@"auto", @"lazy"],\n              @"pickList": @[@"Auto (Recommended)", @"Lazy / lower CPU overhead"]\n            },\n            @{@"key": @"mvk_argument_buffers",\n              @"title": @"MoltenVK Metal Argument Buffers",\n              @"hasDetail": @YES,\n              @"icon": @"square.stack.3d.up",\n              @"type": self.typePickField,\n              @"enableCondition": whenNotInGame,\n              @"pickKeys": @[@"auto", @"on", @"off"],\n              @"pickList": @[@"Auto / MoltenVK default", @"Force On", @"Force Off"]\n            },\n'''
replace_once(
    UI,
    renderer_ui,
    advanced_ui,
    '@"title": @"Enhanced Performance Profile"',
    "advanced video controls",
)


# Apply backend-specific tuning immediately before the renderer library is
# loaded. Environment variables are reset first so switching profiles/backends
# cannot inherit stale overrides in the same launcher process.
java_anchor = '''    // Preset OpenGL libname\n    const char *glLibName = getenv("POJAV_RENDERER");\n'''
java_block = r'''    // Enhanced v4 adaptive performance governor. This uses public ProcessInfo
    // state only; it never attempts to defeat iOS thermal/power management.
    unsetenv("MVK_CONFIG_FAST_MATH_ENABLED");
    unsetenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS");
    unsetenv("MESA_SHADER_CACHE_DISABLE");
    unsetenv("ZINK_DESCRIPTORS");

    NSString *requestedPerfProfile = getPrefObject(@"video.performance_profile");
    if (![requestedPerfProfile isKindOfClass:NSString.class] || requestedPerfProfile.length == 0) {
        requestedPerfProfile = @"balanced";
    }
    NSString *effectivePerfProfile = requestedPerfProfile;
    NSProcessInfo *enhancedProcess = NSProcessInfo.processInfo;
    NSProcessInfoThermalState enhancedThermal = enhancedProcess.thermalState;
    BOOL enhancedLowPower = enhancedProcess.lowPowerModeEnabled;
    BOOL enhancedThermalGuard = getPrefBool(@"video.thermal_governor");

    if (enhancedThermalGuard) {
        if (enhancedThermal >= NSProcessInfoThermalStateSerious) {
            effectivePerfProfile = @"compatibility";
        } else if (enhancedLowPower &&
                   ([requestedPerfProfile isEqualToString:@"performance"] ||
                    [requestedPerfProfile isEqualToString:@"max"])) {
            effectivePerfProfile = @"balanced";
        }
    }

    if ([effectivePerfProfile isEqualToString:@"compatibility"]) {
        // Fast-math can trade strict floating-point behavior for speed. Turning
        // it off is a useful recovery mode for shader/rendering anomalies.
        setenv("MVK_CONFIG_FAST_MATH_ENABLED", "0", 1);
    } else if ([effectivePerfProfile isEqualToString:@"performance"] ||
               [effectivePerfProfile isEqualToString:@"max"]) {
        setenv("MVK_CONFIG_FAST_MATH_ENABLED", "1", 1);
    }

    BOOL enhancedShaderCache = getPrefBool(@"video.shader_cache");
    setenv("MESA_SHADER_CACHE_DISABLE", enhancedShaderCache ? "false" : "true", 1);

    NSString *enhancedZinkDescriptors = getPrefObject(@"video.zink_descriptors");
    if ([enhancedZinkDescriptors isEqualToString:@"lazy"]) {
        setenv("ZINK_DESCRIPTORS", "lazy", 1);
    } else {
        setenv("ZINK_DESCRIPTORS", "auto", 1);
    }

    NSString *enhancedArgumentBuffers = getPrefObject(@"video.mvk_argument_buffers");
    if ([enhancedArgumentBuffers isEqualToString:@"on"]) {
        setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "1", 1);
    } else if ([enhancedArgumentBuffers isEqualToString:@"off"]) {
        setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "0", 1);
    }

    setenv("AMETHYST_PERFORMANCE_PROFILE", effectivePerfProfile.UTF8String, 1);
    setenv("AMETHYST_THERMAL_GUARD", enhancedThermalGuard ? "1" : "0", 1);
    NSLog(@"[EnhancedPerformance] requested=%@ effective=%@ thermal=%ld lowPower=%@ shaderCache=%@ zinkDescriptors=%@ argumentBuffers=%@",
          requestedPerfProfile, effectivePerfProfile, (long)enhancedThermal,
          enhancedLowPower ? @"YES" : @"NO", enhancedShaderCache ? @"ON" : @"OFF",
          enhancedZinkDescriptors ?: @"auto", enhancedArgumentBuffers ?: @"auto");

    // Preset OpenGL libname
    const char *glLibName = getenv("POJAV_RENDERER");
'''
replace_once(
    JAVA,
    java_anchor,
    java_block,
    '[EnhancedPerformance] requested=',
    "adaptive runtime governor",
)

print("Applied Enhanced v4 performance/driver controls")
