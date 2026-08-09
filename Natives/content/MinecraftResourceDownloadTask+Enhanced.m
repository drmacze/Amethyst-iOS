#import <objc/runtime.h>
#import "MinecraftResourceDownloadTask+Enhanced.h"
#import "ContentHubViewController.h"
#import "LauncherMenuViewController.h"

// These methods already exist in MinecraftResourceDownloadTask.m but are kept
// private by the upstream launcher. The Enhanced category deliberately reuses
// them instead of maintaining a second downloader implementation.
@interface MinecraftResourceDownloadTask ()
- (void)prepareForDownload;
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url
                                            size:(NSUInteger)size
                                             sha:(NSString *)sha
                                         altName:(NSString *)altName
                                          toPath:(NSString *)path
                                         success:(void (^)(void))success;
@end

@implementation MinecraftResourceDownloadTask (Enhanced)

- (void)enhancedDownloadURL:(NSString *)url
                       size:(NSUInteger)size
                       sha1:(NSString *)sha1
                displayName:(NSString *)displayName
                     toPath:(NSString *)path
                 completion:(void (^)(NSString *path))completion {
    [self prepareForDownload];
    NSURLSessionDownloadTask *task = [self createDownloadTask:url
                                                         size:size
                                                          sha:sha1
                                                      altName:displayName
                                                       toPath:path
                                                      success:^{
        if (completion) completion(path);
    }];
    if (task) {
        [task resume];
    } else if (!self.progress.cancelled && completion) {
        // Existing and already-verified file path.
        completion(path);
    }
}

@end

// Keep the v2 menu integration isolated from upstream LauncherMenuViewController.
// This lets Enhanced stay rebasing-friendly: upstream can continue changing its
// sidebar while the extra Content Hub entry is inserted after Preferences.
@implementation LauncherMenuViewController (AmethystEnhancedContentHub)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, @selector(viewDidLoad));
        Method enhanced = class_getInstanceMethod(self, @selector(amethystEnhanced_viewDidLoad));
        method_exchangeImplementations(original, enhanced);
    });
}

- (void)amethystEnhanced_viewDidLoad {
    [self amethystEnhanced_viewDidLoad];

    NSMutableArray<LauncherMenuCustomItem *> *options = [self valueForKey:@"options"];
    if (![options isKindOfClass:NSMutableArray.class]) return;
    for (LauncherMenuCustomItem *existing in options) {
        if ([existing.title isEqualToString:@"Content Hub"]) return;
    }

    ContentHubViewController *vc = [ContentHubViewController new];
    LauncherMenuCustomItem *item = [LauncherMenuCustomItem new];
    item.title = vc.title;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    item.imageName = [vc performSelector:@selector(imageName)];
#pragma clang diagnostic pop
    item.vcArray = @[vc];

    // News, Profiles, Preferences stay in their upstream order. Content Hub is
    // inserted directly after them and before one-shot utility actions.
    [options insertObject:item atIndex:MIN((NSUInteger)3, options.count)];
    [self.tableView reloadData];
}

@end
