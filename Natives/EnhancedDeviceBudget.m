#import "EnhancedDeviceBudget.h"
#import "LauncherPreferences.h"
#import "utils.h"
#import <math.h>

static NSString *const kSmartModeKey = @"internal.smart_settings_mode";
static NSString *const kSmartBaselineKey = @"internal.smart_settings_baseline";
static NSInteger sLastWarningBand = 0;

@implementation EnhancedDeviceBudget

+ (NSArray<NSString *> *)managedKeys {
    return @[
        @"video.renderer", @"video.performance_profile", @"video.resolution",
        @"video.max_framerate", @"video.thermal_governor", @"video.shader_cache",
        @"video.zink_descriptors", @"video.mvk_argument_buffers",
        @"java.auto_ram", @"java.allocated_memory"
    ];
}

+ (NSDictionary *)baseline {
    id value = getPrefObject(kSmartBaselineKey);
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

+ (id)currentValueForFullKey:(NSString *)key {
    return getPrefObject(key);
}

+ (BOOL)value:(id)a equals:(id)b {
    if (a == b) return YES;
    if (!a || !b) return NO;
    if ([a isKindOfClass:NSNumber.class] && [b isKindOfClass:NSNumber.class]) {
        return fabs([a doubleValue] - [b doubleValue]) < 0.001;
    }
    return [a isEqual:b];
}

+ (BOOL)matchesSmartBaseline {
    NSDictionary *base = self.baseline;
    if (base.count == 0) return NO;
    for (NSString *key in self.managedKeys) {
        id baselineValue = base[key];
        if (!baselineValue) continue;
        if (![self value:[self currentValueForFullKey:key] equals:baselineValue]) return NO;
    }
    return YES;
}

+ (double)profileFactor:(NSString *)profile {
    if ([profile isEqualToString:@"compatibility"]) return 0.78;
    if ([profile isEqualToString:@"performance"]) return 1.10;
    if ([profile isEqualToString:@"max"]) return 1.22;
    return 1.0;
}

+ (double)smartUtilizationForProfile:(NSString *)profile {
    // Smart Settings intentionally keeps sustained-performance headroom. The
    // meter's 100% point is therefore ABOVE the Smart recommendation and means
    // the conservative device envelope has been exhausted, not that Smart itself
    // is already red-lined.
    if ([profile isEqualToString:@"compatibility"]) return 0.55;
    if ([profile isEqualToString:@"performance"]) return 0.80;
    if ([profile isEqualToString:@"max"]) return 0.90;
    return 0.68;
}

+ (double)rendererFactor:(NSString *)renderer {
    if ([renderer isEqualToString:@"libOSMesaModern.8.dylib"]) return 1.12;
    if ([renderer isEqualToString:@"libOSMesa.8.dylib"]) return 1.08;
    if ([renderer isEqualToString:@"libtinygl4angle.dylib"]) return 1.05;
    // Auto and MobileGlues are the currently validated baseline path.
    return 1.0;
}

+ (double)currentPressure {
    NSDictionary *base = self.baseline;
    double baselineResolution = [base[@"video.resolution"] doubleValue];
    if (baselineResolution <= 0.0) baselineResolution = MAX(55.0, getPrefFloat(@"video.resolution"));
    double currentResolution = MAX(25.0, getPrefFloat(@"video.resolution"));

    NSString *baseProfile = base[@"video.performance_profile"] ?: @"balanced";
    NSString *currentProfile = getPrefObject(@"video.performance_profile") ?: @"balanced";

    // Start from the sustained utilization intentionally chosen by Smart. Pixel
    // workload grows roughly with the square of a linear render-scale setting.
    double pressure = [self smartUtilizationForProfile:baseProfile];
    pressure *= pow(currentResolution / MAX(25.0, baselineResolution), 2.0);
    double baseProfileFactor = [self profileFactor:baseProfile];
    pressure *= [self profileFactor:currentProfile] / MAX(0.5, baseProfileFactor);

    NSString *baseRenderer = base[@"video.renderer"] ?: @"auto";
    NSString *currentRenderer = getPrefObject(@"video.renderer") ?: @"auto";
    pressure *= [self rendererFactor:currentRenderer] / MAX(0.5, [self rendererFactor:baseRenderer]);

    BOOL baselineHighRefresh = [base[@"video.max_framerate"] boolValue];
    BOOL highRefresh = getPrefBool(@"video.max_framerate");
    if (highRefresh && !baselineHighRefresh) pressure *= 1.12;

    // Disabling safety/cache features reduces the stability margin represented by
    // this meter. These are small penalties, not claims of literal GPU load.
    if (!getPrefBool(@"video.thermal_governor")) pressure *= 1.08;
    if (!getPrefBool(@"video.shader_cache")) pressure *= 1.03;
    if ([getPrefObject(@"video.zink_descriptors") isEqualToString:@"lazy"] &&
        [currentRenderer isEqualToString:@"libOSMesaModern.8.dylib"]) pressure *= 1.04;
    if ([getPrefObject(@"video.mvk_argument_buffers") isEqualToString:@"on"] &&
        [currentRenderer isEqualToString:@"libOSMesaModern.8.dylib"]) pressure *= 1.03;

    // Manual heap allocation can starve Metal/LWJGL/native memory. Compare it to
    // a conservative heap share only when Auto RAM is disabled.
    if (!getPrefBool(@"java.auto_ram")) {
        NSInteger manualMB = getPrefInt(@"java.allocated_memory");
        uint64_t physicalMB = NSProcessInfo.processInfo.physicalMemory >> 20;
        double conservativeHeap = MAX(384.0, physicalMB * 0.25);
        if (manualMB > conservativeHeap) {
            pressure *= MIN(1.30, 1.0 + ((manualMB - conservativeHeap) / MAX(512.0, conservativeHeap)) * 0.20);
        }
    }

    return MAX(0.0, pressure);
}

+ (NSInteger)riskBandForPressure:(double)p {
    if (p >= 1.15) return 4;
    if (p >= 1.0) return 3;
    if (p >= 0.88) return 2;
    if (p >= 0.70) return 1;
    return 0;
}

+ (NSString *)currentModeLabel {
    NSString *mode = getPrefObject(kSmartModeKey);
    return [mode isEqualToString:@"custom"] ? @"Custom" : @"Smart";
}

+ (NSString *)currentRiskText {
    double p = self.currentPressure;
    NSInteger percent = (NSInteger)llround(p * 100.0);
    if (p >= 1.15) return [NSString stringWithFormat:@"%ld%% · Forced / high stability risk", (long)percent];
    if (p >= 1.0) return [NSString stringWithFormat:@"%ld%% · Estimated device envelope reached", (long)percent];
    if (p >= 0.88) return [NSString stringWithFormat:@"%ld%% · Very high load", (long)percent];
    if (p >= 0.70) return [NSString stringWithFormat:@"%ld%% · High load", (long)percent];
    return [NSString stringWithFormat:@"%ld%% · Stable headroom", (long)percent];
}

+ (UIColor *)colorForPressure:(double)p {
    if (p >= 1.0) return UIColor.systemRedColor;
    if (p >= 0.88) return UIColor.systemOrangeColor;
    if (p >= 0.70) return UIColor.systemYellowColor;
    return UIColor.systemGreenColor;
}

+ (void)markSmartBaselineApplied {
    setPrefObject(kSmartModeKey, @"smart");
    sLastWarningBand = [self riskBandForPressure:self.currentPressure];
}

+ (void)restoreBaseline {
    NSDictionary *base = self.baseline;
    for (NSString *key in self.managedKeys) {
        id value = base[key];
        if (value) setPrefObject(key, value);
    }
    [self markSmartBaselineApplied];
}

+ (void)userDidChangePreference:(NSString *)fullKey value:(id)value presenter:(UIViewController *)presenter {
    if (![self.managedKeys containsObject:fullKey]) return;

    // The preference has already been persisted by the caller. Determine mode
    // from the complete current state so reverting every override returns to Smart.
    BOOL matches = [self matchesSmartBaseline];
    setPrefObject(kSmartModeKey, matches ? @"smart" : @"custom");

    double pressure = [self currentPressure];
    NSInteger band = [self riskBandForPressure:pressure];
    NSInteger previous = sLastWarningBand;
    sLastWarningBand = band;

    // Warnings are advisory, never blockers. Only crossing into red/forced bands
    // creates an alert, so dragging a slider does not generate repeated dialogs.
    if (!presenter || band < 3 || band <= previous) return;

    NSString *message = band >= 4
        ? @"This custom configuration is substantially above the stability envelope estimated for this device. Minecraft may stutter, overheat, run out of memory, show renderer errors, or force close. You can keep it for testing, but stability is not guaranteed."
        : @"This custom configuration has reached the estimated stability envelope for this device. Higher settings may cause sustained throttling, lag, rendering errors, or force closes.";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Custom Settings Warning"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep Custom" style:UIAlertActionStyleDestructive handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restore Smart Settings" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self restoreBaseline];
        if ([presenter respondsToSelector:@selector(tableView)]) {
            UITableView *table = [presenter valueForKey:@"tableView"];
            [table reloadData];
            [self refreshBudgetHeader:table.tableHeaderView];
        }
    }]];
    UIViewController *host = presenter;
    while (host.presentedViewController) host = host.presentedViewController;
    [host presentViewController:alert animated:YES completion:nil];
}

+ (UIView *)budgetHeaderViewForWidth:(CGFloat)width {
    CGFloat w = MAX(280.0, width);
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 76)];
    container.accessibilityIdentifier = @"EnhancedDeviceBudgetHeader";

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, w - 32, 20)];
    title.tag = 4101;
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    title.adjustsFontForContentSizeCategory = YES;
    [container addSubview:title];

    UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    bar.tag = 4102;
    bar.frame = CGRectMake(16, 34, w - 32, 8);
    bar.trackTintColor = UIColor.systemGray5Color;
    [container addSubview:bar];

    UILabel *detail = [[UILabel alloc] initWithFrame:CGRectMake(16, 47, w - 32, 20)];
    detail.tag = 4103;
    detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    detail.adjustsFontForContentSizeCategory = YES;
    detail.textColor = UIColor.secondaryLabelColor;
    [container addSubview:detail];

    [self refreshBudgetHeader:container];
    return container;
}

+ (void)refreshBudgetHeader:(UIView *)view {
    if (!view || ![view.accessibilityIdentifier isEqualToString:@"EnhancedDeviceBudgetHeader"]) return;
    UILabel *title = [view viewWithTag:4101];
    UIProgressView *bar = [view viewWithTag:4102];
    UILabel *detail = [view viewWithTag:4103];
    double pressure = self.currentPressure;
    title.text = [NSString stringWithFormat:@"Device Load Budget · %@ mode", self.currentModeLabel];
    bar.progress = (float)MIN(1.0, MAX(0.0, pressure));
    bar.progressTintColor = [self colorForPressure:pressure];
    detail.text = self.currentRiskText;
}

@end
