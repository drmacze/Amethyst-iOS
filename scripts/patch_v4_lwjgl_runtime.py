#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
JAVA = ROOT / "Natives" / "JavaLauncher.m"


def require(cond, msg):
    if not cond:
        raise SystemExit(f"patch_v4_lwjgl_runtime: {msg}")

text = JAVA.read_text(encoding="utf-8")

helper_anchor = "extern char **environ;\n\n"
helper = r'''extern char **environ;

// Minecraft 26.x moved to LWJGL 3.4.x while 1.21.11 still uses the 3.3.x API.
// A single global Java binding cannot safely serve both: newer LWJGL removed
// legacy stb_image_resize entry points that 1.21.11 still calls. Detect what the
// version metadata declares and select a matching, isolated launcher runtime.
static BOOL EnhancedVersionAtLeast(NSString *value, NSInteger major, NSInteger minor, NSInteger patch) {
    if (value.length == 0) return NO;
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@"."];
    NSInteger a = parts.count > 0 ? parts[0].integerValue : 0;
    NSInteger b = parts.count > 1 ? parts[1].integerValue : 0;
    NSInteger c = parts.count > 2 ? parts[2].integerValue : 0;
    if (a != major) return a > major;
    if (b != minor) return b > minor;
    return c >= patch;
}

static NSString *EnhancedDeclaredLWJGLVersion(id launchTarget) {
    if (![launchTarget isKindOfClass:NSDictionary.class]) return nil;
    NSArray *libraries = launchTarget[@"libraries"];
    if (![libraries isKindOfClass:NSArray.class]) return nil;
    for (id entry in libraries) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *name = entry[@"name"];
        if (![name isKindOfClass:NSString.class]) continue;
        if ([name hasPrefix:@"org.lwjgl:lwjgl:"] &&
            ![name containsString:@":natives-"] && ![name hasSuffix:@":unsafe"]) {
            NSArray *bits = [name componentsSeparatedByString:@":"];
            if (bits.count >= 3) return bits[2];
        }
    }
    return nil;
}

static BOOL EnhancedUseModernLWJGL(id launchTarget, int minimumJava) {
    NSString *declared = EnhancedDeclaredLWJGLVersion(launchTarget);
    if (declared.length) return EnhancedVersionAtLeast(declared, 3, 4, 1);
    // In inherited/modded metadata the base Minecraft LWJGL declaration may not
    // survive in this dictionary. Java 25 is the conservative fallback for the
    // current 26.x generation; older Minecraft remains on the legacy stack.
    return minimumJava >= 25;
}

'''
if "EnhancedUseModernLWJGL" not in text:
    require(helper_anchor in text, "helper insertion anchor missing")
    text = text.replace(helper_anchor, helper, 1)

lookup_anchor = '    NSLog(@"[JavaLauncher] Looking for Java %d or later", minVersion);\n'
lookup_block = '''    BOOL enhancedModernLWJGL = EnhancedUseModernLWJGL(launchTarget, minVersion);
    NSString *enhancedLWJGLVersion = EnhancedDeclaredLWJGLVersion(launchTarget);
    NSLog(@"[EnhancedRuntime] LWJGL declared=%@ selected=%@",
          enhancedLWJGLVersion ?: @"unknown",
          enhancedModernLWJGL ? @"3.4.1 iOS" : @"legacy 3.3.x iOS");
    NSLog(@"[JavaLauncher] Looking for Java %d or later", minVersion);
'''
if '[EnhancedRuntime] LWJGL declared=' not in text:
    require(lookup_anchor in text, "runtime selection anchor missing")
    text = text.replace(lookup_anchor, lookup_block, 1)

old_native = '    margv[++margc] = [NSString stringWithFormat:@"-Djava.library.path=%@/Frameworks", NSBundle.mainBundle.bundlePath].UTF8String;\n'
new_native = '''    NSString *frameworkRoot = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];
    NSString *modernLWJGLNative = [frameworkRoot stringByAppendingPathComponent:@"lwjgl-modern"];
    NSString *nativeLibraryPath = enhancedModernLWJGL
        ? [NSString stringWithFormat:@"%@:%@", modernLWJGLNative, frameworkRoot]
        : frameworkRoot;
    margv[++margc] = [NSString stringWithFormat:@"-Djava.library.path=%@", nativeLibraryPath].UTF8String;
    if (enhancedModernLWJGL) {
        // LWJGL's own loader consults this before java.library.path. Keeping the
        // 3.4.1 dylibs in a subdirectory prevents old Minecraft from binding to
        // a newer stb/core ABI by accident.
        margv[++margc] = [NSString stringWithFormat:@"-Dorg.lwjgl.librarypath=%@", modernLWJGLNative].UTF8String;
        margv[++margc] = "-Dorg.lwjgl.system.SharedLibraryExtractPath=";

        // JDK 24+ warns when unnamed/classpath code calls restricted JNI loading
        // APIs and a future release may deny the call. Minecraft/LWJGL/launcher
        // glue intentionally loads signed bundled dylibs, so opt the modern Java
        // 25 path into native access explicitly instead of relying on the warning
        // mode remaining permissive forever.
        margv[++margc] = "--enable-native-access=ALL-UNNAMED";
        NSLog(@"[EnhancedRuntime] modern LWJGL native path=%@; native access enabled for classpath", modernLWJGLNative);
    }
'''
if 'native access enabled for classpath' not in text:
    require(old_native in text, "java.library.path line changed")
    text = text.replace(old_native, new_native, 1)

old_cp = '''    NSString *classpath = [NSString stringWithFormat:@"%@/*", librariesPath];
    if (launchJar) {
        classpath = [classpath stringByAppendingFormat:@":%@", launchTarget];
    }
'''
new_cp = '''    NSMutableArray<NSString *> *bootstrapClasspath = [NSMutableArray new];
    NSArray<NSString *> *bootstrapFiles = [[fm contentsOfDirectoryAtPath:librariesPath error:nil]
        sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *file in bootstrapFiles) {
        if (![file hasSuffix:@".jar"]) continue;
        // Do not let wildcard ordering choose between two incompatible LWJGL
        // Java APIs. `lwjgl.jar` is the legacy JavaApp build product; the two
        // versioned jars are selected explicitly below.
        if ([file hasPrefix:@"lwjgl"]) continue;
        [bootstrapClasspath addObject:[librariesPath stringByAppendingPathComponent:file]];
    }
    NSString *selectedLWJGLJar = [librariesPath stringByAppendingPathComponent:
        enhancedModernLWJGL ? @"lwjgl-modern-3.4.1.jar" : @"lwjgl-legacy.jar"];
    if (![fm fileExistsAtPath:selectedLWJGLJar]) {
        NSLog(@"[EnhancedRuntime] ERROR selected LWJGL jar missing: %@", selectedLWJGLJar);
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:@"Enhanced LWJGL runtime is missing: %@", selectedLWJGLJar.lastPathComponent]);
        return 1;
    }
    [bootstrapClasspath addObject:selectedLWJGLJar];
    if (launchJar) [bootstrapClasspath addObject:launchTarget];
    NSString *classpath = [bootstrapClasspath componentsJoinedByString:@":"];
'''
if 'selected LWJGL jar missing' not in text:
    require(old_cp in text, "bootstrap classpath block changed")
    text = text.replace(old_cp, new_cp, 1)

JAVA.write_text(text, encoding="utf-8")
print("Applied Enhanced v4.1 dual-LWJGL runtime selector")
