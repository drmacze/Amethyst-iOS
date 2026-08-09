#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, EnhancedContentProvider) {
    EnhancedContentProviderModrinth = 0,
    EnhancedContentProviderCurseForge = 1,
};

typedef NS_ENUM(NSInteger, EnhancedContentType) {
    EnhancedContentTypeMod = 0,
    EnhancedContentTypeModpack,
    EnhancedContentTypeResourcePack,
    EnhancedContentTypeShader,
    EnhancedContentTypeWorld,
};

@interface EnhancedContentAPI : NSObject

@property(nonatomic, readonly) EnhancedContentProvider provider;
@property(nonatomic, readonly) BOOL reachedLastPage;
@property(nonatomic, readonly, nullable) NSError *lastError;

- (instancetype)initWithProvider:(EnhancedContentProvider)provider;

+ (NSString *)nameForProvider:(EnhancedContentProvider)provider;
+ (NSString *)nameForType:(EnhancedContentType)type;
+ (NSString *)modrinthProjectTypeForType:(EnhancedContentType)type;
+ (NSString *)currentMinecraftVersion;
+ (nullable NSString *)currentModLoader;
+ (NSString *)currentGameDirectory;

- (BOOL)isAvailable;
- (nullable NSString *)availabilityMessage;

// Returns normalized dictionaries with keys:
// provider, type, id, title, description, imageUrl, downloads, sourceObject.
- (nullable NSMutableArray<NSMutableDictionary *> *)searchType:(EnhancedContentType)type
                                                        query:(NSString *)query
                                             minecraftVersion:(nullable NSString *)minecraftVersion
                                                       loader:(nullable NSString *)loader
                                                       offset:(NSUInteger)offset;

// Returns normalized dictionaries with keys:
// name, versionNumber, gameVersions, loaders, filename, url, size, sha1,
// projectId, fileId, sourceObject.
- (nullable NSArray<NSMutableDictionary *> *)versionsForItem:(NSDictionary *)item
                                           minecraftVersion:(nullable NSString *)minecraftVersion
                                                     loader:(nullable NSString *)loader;

@end

NS_ASSUME_NONNULL_END
