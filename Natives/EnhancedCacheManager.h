#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EnhancedCacheManager : NSObject

+ (void)presentClearCacheFromViewController:(UIViewController *)viewController;
+ (void)performPendingRendererCacheCleanup;

@end

NS_ASSUME_NONNULL_END
