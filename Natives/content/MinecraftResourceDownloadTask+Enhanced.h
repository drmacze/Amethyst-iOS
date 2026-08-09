#import "MinecraftResourceDownloadTask.h"

@interface MinecraftResourceDownloadTask (Enhanced)

// Download one launcher-managed content file while reusing Amethyst's existing
// SHA-1 verification and progress UI. Completion is called only after the file
// has been moved into its final destination and verified.
- (void)enhancedDownloadURL:(NSString *)url
                       size:(NSUInteger)size
                       sha1:(NSString *)sha1
                displayName:(NSString *)displayName
                     toPath:(NSString *)path
                 completion:(void (^)(NSString *path))completion;

@end
