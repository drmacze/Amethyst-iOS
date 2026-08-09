#import "AFNetworking.h"
#import "EnhancedContentAPI.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "config.h"
#import "utils.h"

static NSString * const EnhancedContentErrorDomain = @"dev.amethyst.enhanced.content";
static const NSInteger kMinecraftCurseForgeGameID = 432;

@interface EnhancedContentAPI ()
@property(nonatomic, readwrite) EnhancedContentProvider provider;
@property(nonatomic, readwrite) BOOL reachedLastPage;
@property(nonatomic, readwrite) NSError *lastError;
@property(nonatomic) NSArray<NSDictionary *> *curseForgeCategories;
@end

@implementation EnhancedContentAPI

- (instancetype)initWithProvider:(EnhancedContentProvider)provider {
    self = [super init];
    if (self) {
        _provider = provider;
    }
    return self;
}

+ (NSString *)nameForProvider:(EnhancedContentProvider)provider {
    return provider == EnhancedContentProviderCurseForge ? @"CurseForge" : @"Modrinth";
}

+ (NSString *)nameForType:(EnhancedContentType)type {
    switch (type) {
        case EnhancedContentTypeMod: return @"Mods";
        case EnhancedContentTypeModpack: return @"Modpacks";
        case EnhancedContentTypeResourcePack: return @"Resource Packs";
        case EnhancedContentTypeShader: return @"Shaders";
        case EnhancedContentTypeWorld: return @"Worlds";
    }
}

+ (NSString *)modrinthProjectTypeForType:(EnhancedContentType)type {
    switch (type) {
        case EnhancedContentTypeMod: return @"mod";
        case EnhancedContentTypeModpack: return @"modpack";
        case EnhancedContentTypeResourcePack: return @"resourcepack";
        case EnhancedContentTypeShader: return @"shader";
        case EnhancedContentTypeWorld: return nil;
    }
}

+ (NSString *)currentGameDirectory {
    NSString *root = [NSString stringWithFormat:@"%s/instances/%@/%@",
                      getenv("POJAV_HOME"),
                      getPrefObject(@"general.game_directory") ?: @"default",
                      [PLProfiles resolveKeyForCurrentProfile:@"gameDir"] ?: @"."];
    return root.stringByStandardizingPath;
}

+ (NSString *)currentMinecraftVersion {
    NSString *profileVersion = [PLProfiles resolveKeyForCurrentProfile:@"lastVersionId"];
    if (profileVersion.length == 0) return @"";
    if ([profileVersion isEqualToString:@"latest-release"]) {
        profileVersion = getPrefObject(@"internal.latest_version.release") ?: profileVersion;
    } else if ([profileVersion isEqualToString:@"latest-snapshot"]) {
        profileVersion = getPrefObject(@"internal.latest_version.snapshot") ?: profileVersion;
    }

    NSString *jsonPath = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), profileVersion, profileVersion];
    NSDictionary *json = parseJSONFromFile(jsonPath);
    NSString *inherits = [json isKindOfClass:NSDictionary.class] ? json[@"inheritsFrom"] : nil;
    if (inherits.length > 0) return inherits;

    // Loader-generated ids commonly contain the vanilla version as the final
    // component. Prefer metadata above; this is only a fallback for profiles
    // whose loader JSON has not been downloaded yet.
    for (NSString *marker in @[@"fabric-loader-", @"quilt-loader-", @"neoforge-", @"forge-"]) {
        NSRange range = [profileVersion rangeOfString:marker options:NSCaseInsensitiveSearch];
        if (range.location != NSNotFound) {
            NSArray<NSString *> *parts = [profileVersion componentsSeparatedByString:@"-"];
            NSString *candidate = parts.lastObject;
            if ([candidate containsString:@"."]) return candidate;
        }
    }
    return profileVersion;
}

+ (NSString *)currentModLoader {
    NSString *profileVersion = [[PLProfiles resolveKeyForCurrentProfile:@"lastVersionId"] lowercaseString];
    if ([profileVersion containsString:@"fabric"]) return @"fabric";
    if ([profileVersion containsString:@"quilt"]) return @"quilt";
    if ([profileVersion containsString:@"neoforge"]) return @"neoforge";
    if ([profileVersion containsString:@"forge"]) return @"forge";
    return nil;
}

- (NSString *)curseForgeAPIKey {
    NSString *runtimeKey = getPrefObject(@"content.curseforge_api_key");
    runtimeKey = [runtimeKey stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (runtimeKey.length > 0) return runtimeKey;

    NSString *compiledKey = CONFIG_CURSEFORGE_API_KEY;
    compiledKey = [compiledKey stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return compiledKey.length > 0 ? compiledKey : nil;
}

- (BOOL)isAvailable {
    if (self.provider == EnhancedContentProviderModrinth) return YES;
    return self.curseForgeAPIKey.length > 0;
}

- (NSString *)availabilityMessage {
    if ([self isAvailable]) return nil;
    return @"CurseForge requires an approved x-api-key. Add your own key from Content Hub settings; Amethyst Enhanced does not embed or share an unauthorized key.";
}

- (void)setErrorCode:(NSInteger)code message:(NSString *)message {
    self.lastError = [NSError errorWithDomain:EnhancedContentErrorDomain
                                         code:code
                                     userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown content provider error"}];
}

- (id)GET:(NSString *)url parameters:(NSDictionary *)parameters headers:(NSDictionary *)headers {
    __block id result = nil;
    __block NSError *requestError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    manager.requestSerializer.timeoutInterval = 25.0;
    manager.responseSerializer = [AFJSONResponseSerializer serializer];
    [manager GET:url parameters:parameters headers:headers progress:nil
         success:^(NSURLSessionTask *task, id responseObject) {
             result = responseObject;
             dispatch_semaphore_signal(sem);
         }
         failure:^(NSURLSessionTask *task, NSError *error) {
             requestError = error;
             dispatch_semaphore_signal(sem);
         }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));

    if (!result) {
        self.lastError = requestError ?: [NSError errorWithDomain:EnhancedContentErrorDomain code:408 userInfo:@{NSLocalizedDescriptionKey:@"Content request timed out."}];
    }
    return result;
}

#pragma mark - Modrinth

- (NSMutableArray *)searchModrinthType:(EnhancedContentType)type query:(NSString *)query minecraftVersion:(NSString *)minecraftVersion loader:(NSString *)loader offset:(NSUInteger)offset {
    NSString *projectType = [EnhancedContentAPI modrinthProjectTypeForType:type];
    if (!projectType) {
        [self setErrorCode:400 message:@"Modrinth does not expose downloadable Minecraft worlds as a project type."];
        return nil;
    }

    NSMutableArray *facets = [NSMutableArray arrayWithObject:@[[NSString stringWithFormat:@"project_type:%@", projectType]]];
    if (minecraftVersion.length > 0) [facets addObject:@[[NSString stringWithFormat:@"versions:%@", minecraftVersion]]];
    if (type == EnhancedContentTypeMod && loader.length > 0) [facets addObject:@[[NSString stringWithFormat:@"categories:%@", loader]]];

    NSData *facetData = [NSJSONSerialization dataWithJSONObject:facets options:0 error:nil];
    NSString *facetString = [[NSString alloc] initWithData:facetData encoding:NSUTF8StringEncoding];
    NSDictionary *params = @{
        @"query": query ?: @"",
        @"facets": facetString ?: @"[]",
        @"limit": @50,
        @"offset": @(offset),
        @"index": @"relevance"
    };
    NSDictionary *response = [self GET:@"https://api.modrinth.com/v2/search" parameters:params headers:@{@"User-Agent":@"Amethyst-Enhanced/2"}];
    if (![response isKindOfClass:NSDictionary.class]) return nil;

    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        NSMutableDictionary *item = [NSMutableDictionary new];
        item[@"provider"] = @(EnhancedContentProviderModrinth);
        item[@"type"] = @(type);
        item[@"id"] = hit[@"project_id"] ?: @"";
        item[@"title"] = hit[@"title"] ?: hit[@"slug"] ?: @"Untitled";
        item[@"description"] = hit[@"description"] ?: @"";
        if (hit[@"icon_url"] && hit[@"icon_url"] != NSNull.null) item[@"imageUrl"] = hit[@"icon_url"];
        item[@"downloads"] = hit[@"downloads"] ?: @0;
        item[@"sourceObject"] = hit;
        [result addObject:item];
    }
    NSUInteger total = [response[@"total_hits"] unsignedIntegerValue];
    self.reachedLastPage = offset + result.count >= total;
    return result;
}

- (NSArray *)versionsForModrinthItem:(NSDictionary *)item minecraftVersion:(NSString *)minecraftVersion loader:(NSString *)loader {
    NSString *projectId = item[@"id"];
    if (projectId.length == 0) return @[];
    NSMutableDictionary *params = [NSMutableDictionary new];
    if (minecraftVersion.length > 0) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:@[minecraftVersion] options:0 error:nil];
        params[@"game_versions"] = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    if ([item[@"type"] integerValue] == EnhancedContentTypeMod && loader.length > 0) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:@[loader] options:0 error:nil];
        params[@"loaders"] = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }

    NSString *url = [NSString stringWithFormat:@"https://api.modrinth.com/v2/project/%@/version", projectId];
    NSArray *response = [self GET:url parameters:params headers:@{@"User-Agent":@"Amethyst-Enhanced/2"}];
    if (![response isKindOfClass:NSArray.class]) return nil;

    NSMutableArray *versions = [NSMutableArray new];
    for (NSDictionary *version in response) {
        NSArray *files = version[@"files"];
        NSDictionary *file = [files filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *obj, NSDictionary *bindings) {
            return [obj[@"primary"] boolValue];
        }]].firstObject ?: files.firstObject;
        if (![file isKindOfClass:NSDictionary.class] || [file[@"url"] length] == 0) continue;
        NSMutableDictionary *normalized = [NSMutableDictionary new];
        normalized[@"name"] = version[@"name"] ?: version[@"version_number"] ?: @"Version";
        normalized[@"versionNumber"] = version[@"version_number"] ?: @"";
        normalized[@"gameVersions"] = version[@"game_versions"] ?: @[];
        normalized[@"loaders"] = version[@"loaders"] ?: @[];
        normalized[@"filename"] = file[@"filename"] ?: @"download";
        normalized[@"url"] = file[@"url"];
        normalized[@"size"] = file[@"size"] ?: @0;
        normalized[@"sha1"] = file[@"hashes"][@"sha1"] ?: @"";
        normalized[@"projectId"] = projectId;
        normalized[@"sourceObject"] = version;
        [versions addObject:normalized];
    }
    return versions;
}

#pragma mark - CurseForge

- (NSDictionary *)curseForgeHeaders {
    NSString *key = self.curseForgeAPIKey;
    return key.length > 0 ? @{@"Accept":@"application/json", @"x-api-key":key} : nil;
}

- (NSArray<NSDictionary *> *)loadCurseForgeCategories {
    if (self.curseForgeCategories) return self.curseForgeCategories;
    if (![self isAvailable]) {
        [self setErrorCode:401 message:self.availabilityMessage];
        return nil;
    }
    NSDictionary *response = [self GET:@"https://api.curseforge.com/v1/categories"
                             parameters:@{@"gameId":@(kMinecraftCurseForgeGameID)}
                                headers:self.curseForgeHeaders];
    NSArray *data = response[@"data"];
    if ([data isKindOfClass:NSArray.class]) self.curseForgeCategories = data;
    return self.curseForgeCategories;
}

- (NSArray<NSString *> *)tokensForType:(EnhancedContentType)type {
    switch (type) {
        case EnhancedContentTypeMod: return @[@"mods", @"mod"];
        case EnhancedContentTypeModpack: return @[@"modpacks", @"mod packs", @"modpack"];
        case EnhancedContentTypeResourcePack: return @[@"resource packs", @"resource pack", @"texture packs", @"texture pack"];
        case EnhancedContentTypeShader: return @[@"shaders", @"shader"];
        case EnhancedContentTypeWorld: return @[@"worlds", @"world", @"maps", @"map"];
    }
}

- (NSDictionary *)curseForgeFilterForType:(EnhancedContentType)type {
    NSArray *categories = [self loadCurseForgeCategories];
    if (!categories) return nil;
    NSArray<NSString *> *tokens = [self tokensForType:type];
    NSDictionary *best = nil;
    NSInteger bestScore = -1;
    for (NSDictionary *category in categories) {
        NSString *name = [category[@"name"] ?: @"" lowercaseString];
        NSString *slug = [[category[@"slug"] ?: @"" stringByReplacingOccurrencesOfString:@"-" withString:@" "] lowercaseString];
        for (NSString *token in tokens) {
            NSInteger score = -1;
            if ([name isEqualToString:token] || [slug isEqualToString:token]) score = 100;
            else if ([name containsString:token] || [slug containsString:token]) score = 50;
            if ([category[@"isClass"] boolValue]) score += 20;
            if (score > bestScore) {
                bestScore = score;
                best = category;
            }
        }
    }
    if (!best || bestScore < 0) {
        [self setErrorCode:404 message:[NSString stringWithFormat:@"CurseForge did not expose a category/class matching %@ for Minecraft.", [EnhancedContentAPI nameForType:type]]];
        return nil;
    }

    NSMutableDictionary *filter = [NSMutableDictionary new];
    if ([best[@"isClass"] boolValue]) {
        filter[@"classId"] = best[@"id"];
    } else {
        if (best[@"classId"]) filter[@"classId"] = best[@"classId"];
        filter[@"categoryId"] = best[@"id"];
    }
    return filter;
}

- (NSMutableArray *)searchCurseForgeType:(EnhancedContentType)type query:(NSString *)query minecraftVersion:(NSString *)minecraftVersion offset:(NSUInteger)offset {
    if (![self isAvailable]) {
        [self setErrorCode:401 message:self.availabilityMessage];
        return nil;
    }
    NSDictionary *typeFilter = [self curseForgeFilterForType:type];
    if (!typeFilter) return nil;

    NSMutableDictionary *params = @{
        @"gameId":@(kMinecraftCurseForgeGameID),
        @"searchFilter":query ?: @"",
        @"index":@(offset),
        @"pageSize":@50,
        @"sortOrder":@"desc"
    }.mutableCopy;
    [params addEntriesFromDictionary:typeFilter];
    if (minecraftVersion.length > 0) params[@"gameVersion"] = minecraftVersion;

    NSDictionary *response = [self GET:@"https://api.curseforge.com/v1/mods/search" parameters:params headers:self.curseForgeHeaders];
    NSArray *data = response[@"data"];
    if (![data isKindOfClass:NSArray.class]) return nil;

    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *project in data) {
        NSMutableDictionary *item = [NSMutableDictionary new];
        item[@"provider"] = @(EnhancedContentProviderCurseForge);
        item[@"type"] = @(type);
        item[@"id"] = project[@"id"] ?: @0;
        item[@"title"] = project[@"name"] ?: project[@"slug"] ?: @"Untitled";
        item[@"description"] = project[@"summary"] ?: @"";
        NSString *logo = project[@"logo"][@"thumbnailUrl"] ?: project[@"logo"][@"url"];
        if (logo.length > 0) item[@"imageUrl"] = logo;
        item[@"downloads"] = project[@"downloadCount"] ?: @0;
        item[@"sourceObject"] = project;
        [result addObject:item];
    }
    NSDictionary *pagination = response[@"pagination"];
    NSUInteger total = [pagination[@"totalCount"] unsignedIntegerValue];
    self.reachedLastPage = offset + result.count >= total;
    return result;
}

- (NSString *)sha1ForCurseForgeFile:(NSDictionary *)file {
    for (NSDictionary *hash in file[@"hashes"]) {
        // CurseForge FileHash algorithm 1 is SHA-1.
        if ([hash[@"algo"] integerValue] == 1 && [hash[@"value"] length] > 0) return hash[@"value"];
    }
    return @"";
}

- (NSString *)downloadURLForCurseForgeFile:(NSDictionary *)file projectId:(id)projectId {
    NSString *downloadURL = file[@"downloadUrl"];
    if (downloadURL.length > 0) return downloadURL;
    id fileId = file[@"id"];
    if (!fileId || !projectId) return nil;
    NSString *endpoint = [NSString stringWithFormat:@"https://api.curseforge.com/v1/mods/%@/files/%@/download-url", projectId, fileId];
    NSDictionary *response = [self GET:endpoint parameters:nil headers:self.curseForgeHeaders];
    id data = response[@"data"];
    return [data isKindOfClass:NSString.class] ? data : nil;
}

- (NSArray *)versionsForCurseForgeItem:(NSDictionary *)item minecraftVersion:(NSString *)minecraftVersion {
    if (![self isAvailable]) {
        [self setErrorCode:401 message:self.availabilityMessage];
        return nil;
    }
    id projectId = item[@"id"];
    if (!projectId) return @[];
    NSString *url = [NSString stringWithFormat:@"https://api.curseforge.com/v1/mods/%@/files", projectId];
    NSMutableDictionary *params = [@{@"pageSize":@50, @"index":@0} mutableCopy];
    if (minecraftVersion.length > 0) params[@"gameVersion"] = minecraftVersion;
    NSDictionary *response = [self GET:url parameters:params headers:self.curseForgeHeaders];
    NSArray *files = response[@"data"];
    if (![files isKindOfClass:NSArray.class]) return nil;

    NSMutableArray *versions = [NSMutableArray new];
    for (NSDictionary *file in files) {
        NSString *downloadURL = [self downloadURLForCurseForgeFile:file projectId:projectId];
        if (downloadURL.length == 0) continue; // Author/provider disabled 3rd-party delivery or URL unavailable.
        NSMutableDictionary *normalized = [NSMutableDictionary new];
        normalized[@"name"] = file[@"displayName"] ?: file[@"fileName"] ?: @"Version";
        normalized[@"versionNumber"] = file[@"displayName"] ?: @"";
        normalized[@"gameVersions"] = file[@"gameVersions"] ?: @[];
        normalized[@"loaders"] = @[];
        normalized[@"filename"] = file[@"fileName"] ?: @"download";
        normalized[@"url"] = downloadURL;
        normalized[@"size"] = file[@"fileLength"] ?: @0;
        normalized[@"sha1"] = [self sha1ForCurseForgeFile:file];
        normalized[@"projectId"] = projectId;
        normalized[@"fileId"] = file[@"id"] ?: @0;
        normalized[@"sourceObject"] = file;
        [versions addObject:normalized];
    }
    return versions;
}

#pragma mark - Public routing

- (NSMutableArray *)searchType:(EnhancedContentType)type query:(NSString *)query minecraftVersion:(NSString *)minecraftVersion loader:(NSString *)loader offset:(NSUInteger)offset {
    self.lastError = nil;
    self.reachedLastPage = NO;
    if (self.provider == EnhancedContentProviderCurseForge) {
        return [self searchCurseForgeType:type query:query minecraftVersion:minecraftVersion offset:offset];
    }
    return [self searchModrinthType:type query:query minecraftVersion:minecraftVersion loader:loader offset:offset];
}

- (NSArray *)versionsForItem:(NSDictionary *)item minecraftVersion:(NSString *)minecraftVersion loader:(NSString *)loader {
    self.lastError = nil;
    if (self.provider == EnhancedContentProviderCurseForge) {
        return [self versionsForCurseForgeItem:item minecraftVersion:minecraftVersion];
    }
    return [self versionsForModrinthItem:item minecraftVersion:minecraftVersion loader:loader];
}

@end
