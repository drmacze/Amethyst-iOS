#import "EnhancedCacheManager.h"

static NSString *AEHome(void) {
    const char *home = getenv("POJAV_HOME");
    return home ? [NSString stringWithUTF8String:home] : NSHomeDirectory();
}

static NSString *AERendererRoot(void) {
    return [[AEHome() stringByAppendingPathComponent:@".amethyst"] stringByAppendingPathComponent:@"mobileglues"];
}

static NSString *AERendererResetMarker(void) {
    return [[AEHome() stringByAppendingPathComponent:@".amethyst"] stringByAppendingPathComponent:@"renderer-cache-reset.pending"];
}

static unsigned long long AESizeAtPath(NSString *path) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return 0;
    if (!isDir) {
        return [[[fm attributesOfItemAtPath:path error:nil] objectForKey:NSFileSize] unsignedLongLongValue];
    }

    unsigned long long total = 0;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:path]
                                includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
                                                   options:NSDirectoryEnumerationSkipsHiddenFiles
                                              errorHandler:^BOOL(NSURL *url, NSError *error) {
        NSLog(@"[EnhancedCache] Size scan skipped %@: %@", url.path, error.localizedDescription);
        return YES;
    }];
    for (NSURL *url in enumerator) {
        NSNumber *isRegular = nil;
        NSNumber *fileSize = nil;
        [url getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
        if (!isRegular.boolValue) continue;
        [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
        total += fileSize.unsignedLongLongValue;
    }
    return total;
}

static NSString *AEFormatBytes(unsigned long long bytes) {
    NSByteCountFormatter *formatter = [NSByteCountFormatter new];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    formatter.allowedUnits = NSByteCountFormatterUseAll;
    formatter.includesUnit = YES;
    return [formatter stringFromByteCount:(long long)bytes];
}

static NSArray<NSString *> *AERendererCacheFiles(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray new];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = AERendererRoot();
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:root];
    for (NSString *relative in enumerator) {
        NSString *name = relative.lastPathComponent.lowercaseString;
        if ([name isEqualToString:@"glsl_cache.tmp"] ||
            [name isEqualToString:@"glsl_cache.tmp.new"] ||
            [name hasPrefix:@"shader_cache"] ||
            [name hasPrefix:@"pipeline_cache"]) {
            [paths addObject:[root stringByAppendingPathComponent:relative]];
        }
    }
    return paths;
}

static unsigned long long AERendererCacheSize(void) {
    unsigned long long total = 0;
    for (NSString *path in AERendererCacheFiles()) total += AESizeAtPath(path);
    return total;
}

static unsigned long long AELauncherCacheSize(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    unsigned long long total = 0;
    for (NSString *path in paths) total += AESizeAtPath(path);
    return total;
}

static BOOL AEDeleteRendererCache(NSError **outError) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *firstError = nil;
    for (NSString *path in AERendererCacheFiles()) {
        NSError *error = nil;
        if ([fm fileExistsAtPath:path] && ![fm removeItemAtPath:path error:&error] && !firstError) firstError = error;
    }

    NSString *marker = AERendererResetMarker();
    [fm createDirectoryAtPath:marker.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm createFileAtPath:marker contents:[NSData data] attributes:nil] && !firstError) {
        firstError = [NSError errorWithDomain:@"AmethystEnhanced.Cache" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Could not create renderer reset marker."}];
    }
    if (outError) *outError = firstError;
    return firstError == nil;
}

static BOOL AEDeleteLauncherCache(NSError **outError) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *firstError = nil;
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    for (NSString *root in paths) {
        NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:root error:&firstError];
        for (NSString *child in children ?: @[]) {
            NSError *error = nil;
            [fm removeItemAtPath:[root stringByAppendingPathComponent:child] error:&error];
            if (error && !firstError) firstError = error;
        }
    }
    [NSURLCache.sharedURLCache removeAllCachedResponses];
    if (outError) *outError = firstError;
    return firstError == nil;
}

@implementation EnhancedCacheManager

+ (void)performPendingRendererCacheCleanup {
    NSString *marker = AERendererResetMarker();
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:marker]) return;

    NSError *error = nil;
    for (NSString *path in AERendererCacheFiles()) {
        if ([fm fileExistsAtPath:path] && ![fm removeItemAtPath:path error:&error]) {
            NSLog(@"[EnhancedCache] Cold-start renderer cache removal failed for %@: %@", path, error.localizedDescription);
            return;
        }
    }
    [fm removeItemAtPath:marker error:nil];
    NSLog(@"[EnhancedCache] Pending renderer cache reset completed before renderer launch");
}

+ (void)presentClearCacheFromViewController:(UIViewController *)viewController {
    unsigned long long rendererBytes = AERendererCacheSize();
    unsigned long long launcherBytes = AELauncherCacheSize();
    unsigned long long allBytes = rendererBytes + launcherBytes;

    NSString *message = [NSString stringWithFormat:@"Renderer: %@\nLauncher/network: %@\n\nWorlds, mods, resource packs, shaders and profiles are never deleted.",
                         AEFormatBytes(rendererBytes), AEFormatBytes(launcherBytes)];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Clear Cache"
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Clear Renderer Cache (%@)", AEFormatBytes(rendererBytes)]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSError *error = nil;
        BOOL ok = AEDeleteRendererCache(&error);
        NSString *body = ok
            ? @"Renderer shader/pipeline cache was cleared. For a complete reset, close and reopen Amethyst before the next Minecraft launch."
            : [NSString stringWithFormat:@"Some renderer cache files could not be removed: %@", error.localizedDescription ?: @"Unknown error"];
        UIAlertController *done = [UIAlertController alertControllerWithTitle:ok ? @"Renderer Cache Cleared" : @"Clear Cache Failed"
                                                                       message:body
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [viewController presentViewController:done animated:YES completion:nil];
        NSLog(@"[EnhancedCache] renderer clear requested, previous size=%llu bytes, success=%@", rendererBytes, ok ? @"YES" : @"NO");
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Clear Launcher Cache (%@)", AEFormatBytes(launcherBytes)]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSError *error = nil;
        BOOL ok = AEDeleteLauncherCache(&error);
        NSString *body = ok ? @"Launcher and network cache cleared." : [NSString stringWithFormat:@"Some launcher cache files could not be removed: %@", error.localizedDescription ?: @"Unknown error"];
        UIAlertController *done = [UIAlertController alertControllerWithTitle:ok ? @"Launcher Cache Cleared" : @"Clear Cache Failed"
                                                                       message:body
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [viewController presentViewController:done animated:YES completion:nil];
        NSLog(@"[EnhancedCache] launcher clear requested, previous size=%llu bytes, success=%@", launcherBytes, ok ? @"YES" : @"NO");
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Clear All Safe Cache (%@)", AEFormatBytes(allBytes)]
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        NSError *rendererError = nil;
        NSError *launcherError = nil;
        BOOL rendererOK = AEDeleteRendererCache(&rendererError);
        BOOL launcherOK = AEDeleteLauncherCache(&launcherError);
        BOOL ok = rendererOK && launcherOK;
        NSString *body = ok
            ? @"All safe caches were cleared. Worlds, mods, packs, shaders and profiles were untouched. Close and reopen Amethyst before the next Minecraft launch to guarantee a completely fresh renderer cache."
            : [NSString stringWithFormat:@"Clear completed with errors. Renderer: %@. Launcher: %@.", rendererError.localizedDescription ?: @"OK", launcherError.localizedDescription ?: @"OK"];
        UIAlertController *done = [UIAlertController alertControllerWithTitle:ok ? @"Cache Cleared" : @"Clear Cache Finished"
                                                                       message:body
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [viewController presentViewController:done animated:YES completion:nil];
        NSLog(@"[EnhancedCache] all safe cache clear requested, previous size=%llu bytes, success=%@", allBytes, ok ? @"YES" : @"NO");
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = viewController.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(viewController.view.bounds), CGRectGetMidY(viewController.view.bounds), 1, 1);
    [viewController presentViewController:sheet animated:YES completion:nil];
}

@end
