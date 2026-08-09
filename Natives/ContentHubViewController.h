#import <UIKit/UIKit.h>

// UIKit exposes leftItemsSupplementBackButton, not a right-side equivalent.
// Keep the implementation source readable while mapping the v2 compatibility
// spelling to the supported property at compile time.
#define rightItemsSupplementBackButton leftItemsSupplementBackButton

@interface ContentHubViewController : UITableViewController
@end
