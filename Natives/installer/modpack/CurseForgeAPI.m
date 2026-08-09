#import "AFNetworking.h"
#import "CurseForgeAPI.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "config.h"
#import "utils.h"

static const NSInteger kCurseForgeMinecraftGameID = 432;

@interface CurseForgeAPI ()
@property(nonatomic) NSString *apiKey;
@end

@implementation CurseForgeAPI

- (instancetype)init {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
        NSString *runtimeKey = [getPrefObject(@"content.curseforge_api_key") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *compiledKey = [(NSString *)CONFIG_CURSEFORGE_API_KEY stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        self.apiKey = runtimeKey.length ? runtimeKey : (compiledKey.length ? compiledKey : nil);
    }
    return self;
}

- (id)getCFEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    if (self.apiKey.length == 0) {
        self.lastError = [NSError errorWithDomain:@"dev.amethyst.enhanced.curseforge" code:401 userInfo:@{NSLocalizedDescriptionKey:@"CurseForge requires an approved x-api-key."}];
        return nil;
    }
    __block id result = nil;
    __block NSError *requestError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    manager.requestSerializer.timeoutInterval = 25.0;
    manager.responseSerializer = [AFJSONResponseSerializer serializer];
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    [manager GET:url parameters:params headers:@{@"Accept":@"application/json", @"x-api-key":self.apiKey} progress:nil
         success:^(NSURLSessionTask *task, id responseObject) {
             result = responseObject;
             dispatch_semaphore_signal(sem);
         }
         failure:^(NSURLSessionTask *task, NSError *error) {
             requestError = error;
             dispatch_semaphore_signal(sem);
         }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    if (!result) self.lastError = requestError ?: [NSError errorWithDomain:@"dev.amethyst.enhanced.curseforge" code:408 userInfo:@{NSLocalizedDescriptionKey:@"CurseForge request timed out."}];
    return result;
}

- (NSNumber *)modpackClassID {
    NSDictionary *response = [self getCFEndpoint:@"categories" params:@{@"gameId":@(kCurseForgeMinecraftGameID), @"classesOnly":@YES}];
    for (NSDictionary *category in response[@"data"]) {
        NSString *name = [category[@"name"] lowercaseString];
        NSString *slug = [[category[@"slug"] ?: @"" stringByReplacingOccurrencesOfString:@"-" withString:@" "] lowercaseString];
        if ([name containsString:@"modpack"] || [slug containsString:@"modpack"] || [name containsString:@"mod pack"]) return category[@"id"];
    }
    return nil;
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *,NSString *> *)filters previousPageResult:(NSMutableArray *)prevResult {
    NSNumber *classId = [self modpackClassID];
    if (!classId) return nil;
    NSMutableDictionary *params = [@{
        @"gameId":@(kCurseForgeMinecraftGameID), @"classId":classId,
        @"searchFilter":filters[@"name"] ?: @"", @"pageSize":@50,
        @"index":@(prevResult.count)
    } mutableCopy];
    if ([filters[@"mcVersion"] length]) params[@"gameVersion"] = filters[@"mcVersion"];
    NSDictionary *response = [self getCFEndpoint:@"mods/search" params:params];
    if (![response[@"data"] isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *result = prevResult ?: [NSMutableArray new];
    for (NSDictionary *project in response[@"data"]) {
        NSMutableDictionary *item = [@{
            @"apiSource":@(2),
            @"isModpack":@YES,
            @"id":project[@"id"] ?: @0,
            @"title":project[@"name"] ?: @"Untitled",
            @"description":project[@"summary"] ?: @""
        } mutableCopy];
        NSString *icon = project[@"logo"][@"thumbnailUrl"] ?: project[@"logo"][@"url"];
        if (icon) item[@"imageUrl"] = icon;
        [result addObject:item];
    }
    NSDictionary *pagination = response[@"pagination"];
    self.reachedLastPage = result.count >= [pagination[@"totalCount"] unsignedIntegerValue];
    return result;
}

- (NSString *)sha1FromFile:(NSDictionary *)file {
    for (NSDictionary *hash in file[@"hashes"]) {
        if ([hash[@"algo"] integerValue] == 1) return hash[@"value"] ?: @"";
    }
    return @"";
}

- (NSString *)downloadURLForProject:(id)projectId file:(NSDictionary *)file {
    NSString *url = file[@"downloadUrl"];
    if (url.length) return url;
    id fileId = file[@"id"];
    if (!fileId) return nil;
    NSDictionary *response = [self getCFEndpoint:[NSString stringWithFormat:@"mods/%@/files/%@/download-url", projectId, fileId] params:nil];
    return [response[@"data"] isKindOfClass:NSString.class] ? response[@"data"] : nil;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    id projectId = item[@"id"];
    NSDictionary *response = [self getCFEndpoint:[NSString stringWithFormat:@"mods/%@/files", projectId] params:@{@"pageSize":@50}];
    NSArray *files = response[@"data"];
    if (![files isKindOfClass:NSArray.class]) return;
    NSMutableArray *names = [NSMutableArray new], *mcNames = [NSMutableArray new], *urls = [NSMutableArray new], *hashes = [NSMutableArray new], *sizes = [NSMutableArray new];
    for (NSDictionary *file in files) {
        NSString *url = [self downloadURLForProject:projectId file:file];
        if (!url.length) continue;
        [names addObject:file[@"displayName"] ?: file[@"fileName"] ?: @"Version"];
        NSArray *gameVersions = file[@"gameVersions"];
        [mcNames addObject:gameVersions.firstObject ?: @""];
        [urls addObject:url];
        [hashes addObject:[self sha1FromFile:file]];
        [sizes addObject:file[@"fileLength"] ?: @0];
    }
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionSizes"] = sizes;
    item[@"versionDetailsLoaded"] = @YES;
}

- (NSDictionary *)fileForProject:(id)projectId fileId:(id)fileId {
    NSDictionary *response = [self getCFEndpoint:[NSString stringWithFormat:@"mods/%@/files/%@", projectId, fileId] params:nil];
    return [response[@"data"] isKindOfClass:NSDictionary.class] ? response[@"data"] : nil;
}

- (NSDictionary *)dependencyInfoForManifest:(NSDictionary *)manifest {
    NSString *minecraft = manifest[@"minecraft"][@"version"];
    if (!minecraft.length) return @{};
    NSDictionary *primary = nil;
    for (NSDictionary *loader in manifest[@"minecraft"][@"modLoaders"]) {
        if ([loader[@"primary"] boolValue]) { primary = loader; break; }
    }
    primary = primary ?: [manifest[@"minecraft"][@"modLoaders"] firstObject];
    NSString *loaderId = primary[@"id"];
    NSMutableDictionary *dependency = [@{@"minecraft":minecraft} mutableCopy];
    if ([loaderId hasPrefix:@"forge-"]) dependency[@"forge"] = [loaderId substringFromIndex:6];
    else if ([loaderId hasPrefix:@"fabric-"]) dependency[@"fabric-loader"] = [loaderId substringFromIndex:7];
    else if ([loaderId hasPrefix:@"quilt-"]) dependency[@"quilt-loader"] = [loaderId substringFromIndex:6];
    return [ModpackUtils infoForDependencies:dependency] ?: @{};
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (!archive || error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open CurseForge modpack: %@", error.localizedDescription ?: @"invalid ZIP"]];
        return;
    }
    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&error];
    NSDictionary *manifest = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&error] : nil;
    if (![manifest isKindOfClass:NSDictionary.class] || error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Invalid CurseForge manifest.json: %@", error.localizedDescription ?: @"missing manifest"]];
        return;
    }
    if (self.apiKey.length == 0) {
        [downloader finishDownloadWithErrorString:@"CurseForge modpack dependency downloads require an approved x-api-key."];
        return;
    }

    NSString *modsPath = [destPath stringByAppendingPathComponent:@"mods"];
    [NSFileManager.defaultManager createDirectoryAtPath:modsPath withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSDictionary *entry in manifest[@"files"]) {
        id projectId = entry[@"projectID"] ?: entry[@"projectId"];
        id fileId = entry[@"fileID"] ?: entry[@"fileId"];
        if (!projectId || !fileId) continue;
        NSDictionary *file = [self fileForProject:projectId fileId:fileId];
        if (!file) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"CurseForge dependency %@/%@ could not be resolved.", projectId, fileId]];
            return;
        }
        NSString *url = [self downloadURLForProject:projectId file:file];
        if (!url.length) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"CurseForge file %@/%@ is not available for third-party delivery.", projectId, fileId]];
            return;
        }
        NSString *fileName = [file[@"fileName"] lastPathComponent];
        if (!fileName.length) continue;
        NSString *path = [modsPath stringByAppendingPathComponent:fileName];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url
                                                                   size:[file[@"fileLength"] unsignedLongLongValue]
                                                                    sha:[self sha1FromFile:file]
                                                                altName:fileName
                                                                 toPath:path];
        if (task) {
            [task resume];
        } else if (downloader.progress.cancelled) {
            return;
        }
    }

    NSString *overrides = manifest[@"overrides"];
    if (![overrides isKindOfClass:NSString.class] || overrides.length == 0) overrides = @"overrides";
    [ModpackUtils archive:archive extractDirectory:overrides toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract CurseForge overrides: %@", error.localizedDescription]];
        return;
    }
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    NSDictionary *depInfo = [self dependencyInfoForManifest:manifest];
    NSString *versionId = depInfo[@"id"] ?: manifest[@"minecraft"][@"version"];
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), versionId];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:[NSString stringWithFormat:@"%@.json", versionId] toPath:jsonPath];
        [task resume];
    }

    NSString *name = manifest[@"name"] ?: destPath.lastPathComponent;
    PLProfiles.current.profiles[name] = [@{
        @"gameDir":[NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name":name,
        @"lastVersionId":versionId ?: @"latest-release"
    } mutableCopy];
    PLProfiles.current.selectedProfileName = name;
    [PLProfiles.current save];
}

@end
