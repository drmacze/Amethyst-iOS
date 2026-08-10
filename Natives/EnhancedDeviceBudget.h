#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EnhancedDeviceBudget : NSObject

/// Returns a 0...1+ pressure ratio. 1.0 means the current configuration reaches
/// the conservative device envelope derived by Smart Settings. Values above 1
/// are allowed, but are intentionally reported as over-budget.
+ (double)currentPressure;
+ (NSString *)currentModeLabel;
+ (NSString *)currentRiskText;
+
/// Called after a user changes a performance-sensitive preference. Smart mode
/// becomes Custom when the value no longer matches the last Smart baseline.
/// A warning is presented only when crossing into a higher risk band, avoiding
/// alert spam while sliders are dragged.
+ (void)userDidChangePreference:(NSString *)fullKey
                         value:(id)value
                     presenter:(UIViewController * _Nullable)presenter;
+
/// Builds/updates the visual budget meter used by Settings.
+ (UIView *)budgetHeaderViewForWidth:(CGFloat)width;
+ (void)refreshBudgetHeader:(UIView * _Nullable)view;
+
/// Reset Custom state after Smart Settings intentionally applies a fresh baseline.
+ (void)markSmartBaselineApplied;
+
@end

NS_ASSUME_NONNULL_END
