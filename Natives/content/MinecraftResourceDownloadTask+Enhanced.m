#import "MinecraftResourceDownloadTask+Enhanced.h"

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
