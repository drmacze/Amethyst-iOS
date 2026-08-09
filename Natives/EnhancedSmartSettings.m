#import "EnhancedSmartSettings.h"
#import "LauncherPreferences.h"

#import <Metal/Metal.h>
#import <sys/sysctl.h>
#import <unistd.h>

static const NSInteger kEnhancedSmartSettingsLogicVersion = 4;

@implementation EnhancedSmartSettings

#pragma mark - Capability probing

+ (NSString *)machineIdentifier {
    size_t size = 0;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    if (size == 0) return @"unknown";
    char *machine = calloc(1, size);
    if (!machine) return @"unknown";
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    NSString *result = [NSString stringWithUTF8String:machine] ?: @"unknown";
    free(machine);
    return result;
}

+ (NSInteger)metalCapabilityTier:(id<MTLDevice>)device {
    if (!device) return 0;
    if (@available(iOS 13.0, *)) {
        // We deliberately group future GPUs at the highest capability class we
        // know how to tune safely instead of guessing undocumented behavior.
        if ([device supportsFamily:MTLGPUFamilyApple7]) return 7;
        if ([device supportsFamily:MTLGPUFamilyApple6]) return 6;
        if ([device supportsFamily:MTLGPUFamilyApple5]) return 5;
        if ([device supportsFamily:MTLGPUFamilyApple4]) return 4;
        if ([device supportsFamily:MTLGPUFamilyApple3]) return 3;
        if ([device supportsFamily:MTLGPUFamilyApple2]) return 2;
        if ([device supportsFamily:MTLGPUFamilyApple1]) return 1;
    }
    return 1;
}

+ (NSDictionary *)deviceSnapshotWithProgress:(void (^)(float, NSString *))progress {
    if (progress) progress(0.08f, @"Reading iPhone model and iOS version…");
    NSString *machine = self.machineIdentifier;
    NSString *osVersion = UIDevice.currentDevice.systemVersion ?: @"unknown";
    usleep(70000);

    if (progress) progress(0.22f, @"Measuring memory and CPU capacity…");
    uint64_t memoryBytes = NSProcessInfo.processInfo.physicalMemory;
    NSInteger activeCPUs = NSProcessInfo.processInfo.activeProcessorCount;
    usleep(70000);

    if (progress) progress(0.40f, @"Probing Metal GPU capabilities…");
    id<MTLDevice> metal = MTLCreateSystemDefaultDevice();
    NSInteger metalTier = [self metalCapabilityTier:metal];
    NSUInteger maxBufferLength = 0;
    if (metal && [metal respondsToSelector:@selector(maxBufferLength)]) {
        maxBufferLength = metal.maxBufferLength;
    }
    usleep(70000);

    if (progress) progress(0.58f, @"Calculating native display workload…");
    CGRect nativeBounds = UIScreen.mainScreen.nativeBounds;
    double nativePixels = nativeBounds.size.width * nativeBounds.size.height;
    NSInteger maxFPS = UIScreen.mainScreen.maximumFramesPerSecond;
    usleep(70000);

    if (progress) progress(0.73f, @"Checking thermal and power conditions…");
    NSProcessInfo *process = NSProcessInfo.processInfo;
    NSInteger thermalState = NSProcessInfoThermalStateNominal;
    BOOL lowPowerMode = NO;
    if (@available(iOS 11.0, *)) {
        thermalState = process.thermalState;
        lowPowerMode = process.lowPowerModeEnabled;
    }
    usleep(70000);

    if (progress) progress(0.84f, @"Building a stability-first device profile…");
    return @{
        @"machine": machine,
        @"os": osVersion,
        @"memoryBytes": @(memoryBytes),
        @"activeCPUs": @(activeCPUs),
        @"metalTier": @(metalTier),
        @"maxBufferLength": @(maxBufferLength),
        @"nativePixels": @(nativePixels),
        @"maxFPS": @(maxFPS),
        @"thermalState": @(thermalState),
        @"lowPowerMode": @(lowPowerMode),
        @"metalName": metal.name ?: @"Unavailable"
    };
}

+ (NSString *)fingerprintForSnapshot:(NSDictionary *)snapshot {
    // Thermal/Low Power are intentionally excluded because they are transient.
    // The runtime governor handles them every launch. A rescan is required when
    // hardware, OS, display capability, or Smart Settings logic changes.
    uint64_t memoryMB = [snapshot[@"memoryBytes"] unsignedLongLongValue] >> 20;
    uint64_t memoryBucket = (memoryMB / 512) * 512;
    return [NSString stringWithFormat:@"v%ld|%@|%@|mem%llu|cpu%ld|gpu%ld|fps%ld",
            (long)kEnhancedSmartSettingsLogicVersion,
            snapshot[@"machine"] ?: @"unknown",
            snapshot[@"os"] ?: @"unknown",
            memoryBucket,
            (long)[snapshot[@"activeCPUs"] integerValue],
            (long)[snapshot[@"metalTier"] integerValue],
            (long)[snapshot[@"maxFPS"] integerValue]];
}

+ (NSDictionary *)quickSnapshot {
    id<MTLDevice> metal = MTLCreateSystemDefaultDevice();
    return @{
        @"machine": self.machineIdentifier,
        @"os": UIDevice.currentDevice.systemVersion ?: @"unknown",
        @"memoryBytes": @(NSProcessInfo.processInfo.physicalMemory),
        @"activeCPUs": @(NSProcessInfo.processInfo.activeProcessorCount),
        @"metalTier": @([self metalCapabilityTier:metal]),
        @"maxFPS": @(UIScreen.mainScreen.maximumFramesPerSecond)
    };
}

#pragma mark - Recommendation engine

+ (NSString *)recommendedProfileFor:(NSDictionary *)s {
    double memoryGB = [s[@"memoryBytes"] unsignedLongLongValue] / 1073741824.0;
    NSInteger gpu = [s[@"metalTier"] integerValue];
    NSInteger cpus = [s[@"activeCPUs"] integerValue];
    NSInteger thermal = [s[@"thermalState"] integerValue];
    BOOL lowPower = [s[@"lowPowerMode"] boolValue];

    // Stable baseline. We only select aggressive tiers when BOTH memory and GPU
    // capability support them; CPU count is a secondary guard, not a device-name
    // guess. Current heat/power state can only lower the recommendation.
    NSString *profile;
    if (gpu == 0 || memoryGB < 3.5 || gpu < 5 || cpus < 4) {
        profile = @"compatibility";
    } else if (memoryGB >= 7.5 && gpu >= 7 && cpus >= 6) {
        profile = @"max";
    } else if (memoryGB >= 5.5 && gpu >= 7 && cpus >= 6) {
        profile = @"performance";
    } else {
        profile = @"balanced";
    }

    if (thermal >= NSProcessInfoThermalStateSerious) {
        return @"compatibility";
    }
    if (lowPower && ([profile isEqualToString:@"max"] || [profile isEqualToString:@"performance"])) {
        return @"balanced";
    }
    return profile;
}

+ (NSInteger)recommendedResolutionFor:(NSDictionary *)s profile:(NSString *)profile {
    double nativePixels = MAX(1.0, [s[@"nativePixels"] doubleValue]);
    double targetMP = 1.05; // Balanced: conservative sustained-performance target.
    if ([profile isEqualToString:@"compatibility"]) targetMP = 0.78;
    else if ([profile isEqualToString:@"performance"]) targetMP = 1.35;
    else if ([profile isEqualToString:@"max"]) targetMP = 1.70;

    NSInteger gpu = [s[@"metalTier"] integerValue];
    double memoryGB = [s[@"memoryBytes"] unsignedLongLongValue] / 1073741824.0;
    if (gpu <= 5) targetMP *= 0.90;
    if (memoryGB < 4.0) targetMP *= 0.88;

    // Resolution is a linear dimension percentage, therefore pixel load scales
    // with the square. sqrt(target/native) converts the pixel budget correctly.
    double scale = sqrt((targetMP * 1000000.0) / nativePixels) * 100.0;
    NSInteger percent = (NSInteger)llround(scale);
    return MAX(55, MIN(100, percent));
}

+ (NSDictionary *)recommendationFor:(NSDictionary *)snapshot {
    NSString *profile = [self recommendedProfileFor:snapshot];
    NSInteger resolution = [self recommendedResolutionFor:snapshot profile:profile];
    NSInteger maxFPS = [snapshot[@"maxFPS"] integerValue];

    // 120 Hz is only unlocked automatically for the strongest profile. This is
    // intentionally conservative because chasing 120 FPS is a common source of
    // sustained thermal throttling on phones.
    BOOL unlockHighRefresh = maxFPS > 60 && [profile isEqualToString:@"max"];

    return @{
        @"profile": profile,
        @"resolution": @(resolution),
        @"maxFramerate": @(unlockHighRefresh),
        @"renderer": @"auto",
        @"thermalGovernor": @YES,
        @"shaderCache": @YES,
        @"zinkDescriptors": @"auto",
        @"mvkArgumentBuffers": @"auto",
        @"autoRAM": @YES
    };
}

+ (NSString *)displayNameForProfile:(NSString *)profile {
    if ([profile isEqualToString:@"compatibility"]) return @"Compatibility";
    if ([profile isEqualToString:@"performance"]) return @"Performance";
    if ([profile isEqualToString:@"max"]) return @"Max Performance";
    return @"Balanced";
}

+ (NSString *)applyRecommendation:(NSDictionary *)r snapshot:(NSDictionary *)s {
    setPrefObject(@"video.renderer", r[@"renderer"]);
    setPrefObject(@"video.performance_profile", r[@"profile"]);
    setPrefObject(@"video.resolution", r[@"resolution"]);
    setPrefObject(@"video.max_framerate", r[@"maxFramerate"]);
    setPrefObject(@"video.thermal_governor", r[@"thermalGovernor"]);
    setPrefObject(@"video.shader_cache", r[@"shaderCache"]);
    setPrefObject(@"video.zink_descriptors", r[@"zinkDescriptors"]);
    setPrefObject(@"video.mvk_argument_buffers", r[@"mvkArgumentBuffers"]);
    setPrefObject(@"java.auto_ram", r[@"autoRAM"]);

    NSString *fingerprint = [self fingerprintForSnapshot:s];
    NSString *summary = [NSString stringWithFormat:
        @"%@ · %@ · %ld%% render scale · Auto RAM · Thermal Guard",
        s[@"machine"] ?: @"iPhone",
        [self displayNameForProfile:r[@"profile"]],
        (long)[r[@"resolution"] integerValue]];
    setPrefObject(@"internal.smart_settings_fingerprint", fingerprint);
    setPrefObject(@"internal.smart_settings_summary", summary);
    setPrefObject(@"internal.smart_settings_logic_version", @(kEnhancedSmartSettingsLogicVersion));

    NSLog(@"[SmartSettings] device=%@ iOS=%@ RAM=%.2fGB cpu=%ld metalTier=%ld metal=%@ nativePixels=%.0f maxFPS=%ld thermal=%ld lowPower=%@",
          s[@"machine"], s[@"os"],
          [s[@"memoryBytes"] unsignedLongLongValue] / 1073741824.0,
          (long)[s[@"activeCPUs"] integerValue], (long)[s[@"metalTier"] integerValue],
          s[@"metalName"], [s[@"nativePixels"] doubleValue], (long)[s[@"maxFPS"] integerValue],
          (long)[s[@"thermalState"] integerValue], [s[@"lowPowerMode"] boolValue] ? @"YES" : @"NO");
    NSLog(@"[SmartSettings] applied profile=%@ resolution=%@ highRefresh=%@ renderer=auto autoRAM=YES fingerprint=%@",
          r[@"profile"], r[@"resolution"], [r[@"maxFramerate"] boolValue] ? @"YES" : @"NO", fingerprint);
    return summary;
}

#pragma mark - Presentation

+ (UIViewController *)topPresenter:(UIViewController *)vc {
    UIViewController *current = vc;
    while (current.presentedViewController && !current.presentedViewController.isBeingDismissed) {
        current = current.presentedViewController;
    }
    if ([current isKindOfClass:UINavigationController.class]) {
        return [self topPresenter:((UINavigationController *)current).visibleViewController ?: current];
    }
    if ([current isKindOfClass:UISplitViewController.class]) {
        UIViewController *last = ((UISplitViewController *)current).viewControllers.lastObject;
        if (last) return [self topPresenter:last];
    }
    return current;
}

+ (void)presentScanFrom:(UIViewController *)presenter
                  force:(BOOL)force
             completion:(void (^)(void))completion {
    if (!presenter) {
        if (completion) completion();
        return;
    }

    NSDictionary *quick = self.quickSnapshot;
    NSString *newFingerprint = [self fingerprintForSnapshot:quick];
    NSString *oldFingerprint = getPrefObject(@"internal.smart_settings_fingerprint");
    if (!force && oldFingerprint.length && [oldFingerprint isEqualToString:newFingerprint]) {
        if (completion) completion();
        return;
    }

    UIViewController *host = [self topPresenter:presenter];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Smart Settings"
        message:@"Preparing device scan…\n\n\n" preferredStyle:UIAlertControllerStyleAlert];

    UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.progress = 0.02f;
    UILabel *status = [UILabel new];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.text = @"Initializing capability engine…";
    status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    status.textAlignment = NSTextAlignmentCenter;
    status.numberOfLines = 2;

    [alert.view addSubview:bar];
    [alert.view addSubview:status];
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:alert.view.leadingAnchor constant:24],
        [bar.trailingAnchor constraintEqualToAnchor:alert.view.trailingAnchor constant:-24],
        [bar.topAnchor constraintEqualToAnchor:alert.view.topAnchor constant:82],
        [status.leadingAnchor constraintEqualToAnchor:alert.view.leadingAnchor constant:18],
        [status.trailingAnchor constraintEqualToAnchor:alert.view.trailingAnchor constant:-18],
        [status.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:10]
    ]];

    [host presentViewController:alert animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *snapshot = [self deviceSnapshotWithProgress:^(float value, NSString *text) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [bar setProgress:value animated:YES];
                    status.text = text;
                });
            }];
            NSDictionary *recommendation = [self recommendationFor:snapshot];

            dispatch_async(dispatch_get_main_queue(), ^{
                [bar setProgress:0.94f animated:YES];
                status.text = @"Applying renderer, memory, display and safety settings…";
            });
            usleep(80000);

            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *summary = [self applyRecommendation:recommendation snapshot:snapshot];
                [bar setProgress:1.0f animated:YES];
                alert.title = @"Smart Settings Ready";
                status.text = summary;

                if (force) {
                    [alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                        if (completion) completion();
                    }]];
                } else {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [alert dismissViewControllerAnimated:YES completion:completion];
                    });
                }
            });
        });
    }];
}

+ (void)runAutomaticScanIfNeededFrom:(UIViewController *)presenter {
    if (!presenter) return;

    // Preferences can finish loading just after the initial scene is shown.
    // Retry briefly rather than treating a not-yet-loaded store as "disabled".
    __block NSInteger attempts = 0;
    __weak UIViewController *weakPresenter = presenter;
    __block void (^retry)(void) = nil;
    retry = ^{
        UIViewController *strongPresenter = weakPresenter;
        if (!strongPresenter) return;
        id rendererPref = getPrefObject(@"video.renderer");
        if (!rendererPref && attempts++ < 12) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), retry);
            return;
        }
        if (!getPrefBool(@"video.smart_settings")) return;
        [self presentScanFrom:strongPresenter force:NO completion:nil];
        retry = nil;
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), retry);
}

+ (NSString *)lastSummary {
    NSString *summary = getPrefObject(@"internal.smart_settings_summary");
    return [summary isKindOfClass:NSString.class] ? summary : @"Not scanned yet";
}

@end
