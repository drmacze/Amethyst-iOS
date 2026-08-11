#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EnhancedSmartSettings : NSObject

/// Runs automatically only when Smart Settings is enabled and the device/OS/
/// tuning-logic fingerprint has changed. The scan is presented visibly and
/// applies a conservative capability-derived configuration.
+ (void)runAutomaticScanIfNeededFrom:(UIViewController *)presenter;

/// Forces a visible rescan and reapplies the computed configuration.
+ (void)presentScanFrom:(UIViewController *)presenter
                  force:(BOOL)force
             completion:(void (^ _Nullable)(void))completion;

/// Human-readable summary of the last applied recommendation.
+ (NSString *)lastSummary;

@end

NS_ASSUME_NONNULL_END
