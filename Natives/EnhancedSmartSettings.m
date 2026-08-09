#import "EnhancedSmartSettings.h"
#import "LauncherPreferences.h"

#import <Metal/Metal.h>
#import <math.h>
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
        // Future GPUs intentionally collapse into the newest capability class we
        // have validated instead of inventing tuning rules for unknown hardware.
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
    // Thermal and Low Power Mode are transient and deliberately excluded. They
    // are handled by the runtime governor on every game launch. Full Smart Scan
    // repeats only when hardware, OS/display capability, or tuning logic changes.
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

    // Persistent recommendation is hardware-derived only. A temporary hot or
    // low-battery state must not permanently downgrade a capable phone. The
    // EnhancedPerformance runtime governor applies thermal/power downgrades at
    // launch time and restores the requested tier naturally when conditions heal.
    if (gpu == 0 || memoryGB < 3.5 || gpu < 5 || cpus < 4) {
        return @"compatibility";
    }
    if (memoryGB >= 7.5 && gpu >= 7 && cpus >= 6) {
        return @"max";
    }
    if (memoryGB >= 5.5 && gpu >= 7 && cpus >= 6) {
        return @"performance";
    }
    return @"balanced";
}

+ (NSInteger)recommendedResolutionFor:(NSDictionary *)s profile:(NSString *)profile {
    double nativePixels = MAX(1.0, [s[@"nativePixels"] doubleValue]);
    double targetMP = 1.05; // Balanced sustained-rendering pixel budget.
    if ([profile isEqualToString:@"compatibility"]) targetMP = 0.78;
    else if ([profile isEqualToString:@"performance"]) targetMP = 1.35;
    else if ([profile isEqualToString:@"max"]) targetMP = 1.70;

    NSInteger gpu = [s[@"metalTier"] integerValue];
    double memoryGB = [s[@"memoryBytes"] unsignedLongLongValue] / 1073741824.0;
    if (gpu <= 5) targetMP *= 0.90;
    if (memoryGB < 4.0) targetMP *= 0.88;

    // Pixel cost is approximately quadratic in a linear render-scale setting.
    // sqrt(target/native) converts our pixel budget into the launcher's percent.
    double scale = sqrt((targetMP * 1000000.0) / nativePixels) * 100.0;
    NSInteger percent = (NSInteger)llround(scale);
    return MAX(55, MIN(100, percent));
}

+ (NSDictionary *)recommendationFor:(NSDictionary *)snapshot {
    NSString *profile = [self recommendedProfileFor:snapshot];
    NSInteger resolution = [self recommendedResolutionFor:snapshot profile:profile];
    NSInteger maxFPS = [snapshot[@"maxFPS"] integerValue];

    // 120 Hz is unlocked automatically only for the strongest hardware profile.
    // This avoids choosing a thermally expensive target merely because ProMotion
    // exists. Users can still override it manually after Smart Settings.
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
    // Auto renderer intentionally stays on the validated MobileGlues baseline.
    // Smart Settings tunes the device around a known-safe default instead of
    // promoting experimental Zink simply because a phone is newer.
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
    NSString *powerNote = [s[@"lowPowerMode"] boolValue] ? @" · Low Power currently active" : @"";
    NSString *summary = [NSString stringWithFormat:
        @"%@ · %@ · %ld%% render scale · Auto RAM · Thermal Guard%@",
        s[@"machine"] ?: @"iPhone",
        [self displayNameForProfile:r[@"profile"]],
        (long)[r[@"resolution"] integerValue], powerNote];
    setPrefObject(@"internal.smart_settings_fingerprint", fingerprint);
    setPrefObject(@"internal.smart_settings_summary", summary);
    setPrefObject(@"internal.smart_settings_logic_version", @(kEnhancedSmartSettingsLogicVersion));

    NSLog(@"[SmartSettings] device=%@ iOS=%@ RAM=%.2fGB cpu=%ld metalTier=%ld metal=%@ maxBuffer=%lluMB nativePixels=%.0f maxFPS=%ld thermal=%ld lowPower=%@",
          s[@"machine"], s[@"os"],
          [s[@"memoryBytes"] unsignedLongLongValue] / 1073741824.0,
          (long)[s[@"activeCPUs"] integerValue], (long)[s[@"metalTier"] integerValue],
          s[@"metalName"], [s[@"maxBufferLength"] unsignedLongLongValue] >> 20,
          [s[@"nativePixels"] doubleValue], (long)[s[@"maxFPS"] integerValue],
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

+ (void)scheduleAutomaticScanFrom:(UIViewController *)presenter attempt:(NSInteger)attempt {
    if (!presenter || attempt > 12) return;
    id rendererPref = getPrefObject(@"video.renderer");
    if (!rendererPref) {
        __weak UIViewController *weakPresenter = presenter;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *strongPresenter = weakPresenter;
            if (strongPresenter) [self scheduleAutomaticScanFrom:strongPresenter attempt:attempt + 1];
        });
        return;
    }
    if (!getPrefBool(@"video.smart_settings")) return;
    [self presentScanFrom:presenter force:NO completion:nil];
}

+ (void)runAutomaticScanIfNeededFrom:(UIViewController *)presenter {
    if (!presenter) return;
    __weak UIViewController *weakPresenter = presenter;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongPresenter = weakPresenter;
        if (strongPresenter) [self scheduleAutomaticScanFrom:strongPresenter attempt:0];
    });
}

+ (NSString *)lastSummary {
    NSString *summary = getPrefObject(@"internal.smart_settings_summary");
    return [summary isKindOfClass:NSString.class] && summary.length ? summary : @"Not scanned yet";
}

@end
