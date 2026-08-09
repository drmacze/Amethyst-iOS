#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "PLProfiles.h"

static BOOL EnhancedModrinthSafeDestination(NSString *relative, NSString *root, NSString **destination) {
    if (![relative isKindOfClass:NSString.class] || relative.length == 0) return NO;
    if ([relative hasPrefix:@"/"] || [relative hasPrefix:@"~"]) return NO;
    NSArray<NSString *> *components = relative.pathComponents;
    if ([components containsObject:@".."] || [components containsObject:@"~"]) return NO;

    NSString *standardRoot = root.stringByStandardizingPath;
    NSString *rootPrefix = [standardRoot stringByAppendingString:@"/"];
    NSString *standardDestination = [[standardRoot stringByAppendingPathComponent:relative] stringByStandardizingPath];
    if (![standardDestination hasPrefix:rootPrefix]) return NO;
    if (destination) *destination = standardDestination;
    return YES;
}

@implementation ModrinthAPI

- (instancetype)init {
    return [super initWithURL:@"https://api.modrinth.com/v2"];
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult {
    int limit = 50;

    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", searchFilters[@"isModpack"].boolValue ? @"modpack" : @"mod"];
    if (searchFilters[@"mcVersion"].length > 0) {
        [facetString appendFormat:@",[\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    [facetString appendString:@"]"];

    NSDictionary *params = @{
        @"facets": facetString,
        @"query": [searchFilters[@"name"] stringByReplacingOccurrencesOfString:@" " withString:@"+"],
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count)
    };
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        return nil;
    }

    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        [result addObject:@{
            @"apiSource": @(1), // Constant MODRINTH
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"],
            @"title": hit[@"title"],
            @"description": hit[@"description"],
            @"imageUrl": hit[@"icon_url"]
        }.mutableCopy];
    }
    self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:nil];
    if (!response) {
        return;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray new];
    [response enumerateObjectsUsingBlock:^(NSDictionary *version, NSUInteger i, BOOL *stop) {
        NSArray *files = version[@"files"];
        NSDictionary *file = [files isKindOfClass:NSArray.class] ? files.firstObject : nil;
        NSString *url = [file[@"url"] isKindOfClass:NSString.class] ? file[@"url"] : nil;
        if (!url.length) return;

        [names addObject:version[@"name"] ?: version[@"version_number"] ?: @"Version"];
        [mcNames addObject:[version[@"game_versions"] firstObject] ?: @""];
        [sizes addObject:file[@"size"] ?: @0];
        [urls addObject:url];
        [hashes addObject:file[@"hashes"][@"sha1"] ?: @""];
    }];
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (!archive || error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription ?: @"invalid ZIP"]];
        return;
    }

    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    if (!indexData || error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to read modrinth.index.json: %@", error.localizedDescription ?: @"missing index"]];
        return;
    }
    NSDictionary *indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];
    if (![indexDict isKindOfClass:NSDictionary.class] || error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription ?: @"invalid index"]];
        return;
    }

    NSArray *indexFiles = indexDict[@"files"];
    if (![indexFiles isKindOfClass:NSArray.class]) {
        [downloader finishDownloadWithErrorString:@"Invalid Modrinth pack: files is missing or is not an array."];
        return;
    }

    downloader.progress.totalUnitCount = indexFiles.count;
    for (NSDictionary *indexFile in indexFiles) {
        NSArray *downloads = indexFile[@"downloads"];
        NSString *url = [downloads isKindOfClass:NSArray.class] ? downloads.firstObject : nil;
        NSString *relative = indexFile[@"path"];
        NSString *path = nil;
        if (!url.length) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Modrinth pack file %@ has no download URL.", relative ?: @"(unknown)"]];
            return;
        }
        if (!EnhancedModrinthSafeDestination(relative, destPath, &path)) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Unsafe file path blocked in Modrinth pack: %@", relative ?: @"(null)"]];
            return;
        }

        NSString *sha = indexFile[@"hashes"][@"sha1"] ?: @"";
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size sha:sha altName:relative toPath:path];
        if (task) {
            [task resume];
        } else if (!downloader.progress.cancelled) {
            downloader.progress.completedUnitCount++;
        } else {
            return;
        }
    }

    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides from modpack package: %@", error.localizedDescription]];
        return;
    }

    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract client-overrides from modpack package: %@", error.localizedDescription]];
        return;
    }

    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath];
        [task resume];
    }
    // TODO: automation for Forge

    NSString *profileName = indexDict[@"name"] ?: destPath.lastPathComponent;
    NSMutableDictionary *profile = [@{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": profileName,
        @"lastVersionId": depInfo[@"id"] ?: indexDict[@"dependencies"][@"minecraft"] ?: @"latest-release"
    } mutableCopy];
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    if (iconData.length) {
        profile[@"icon"] = [NSString stringWithFormat:@"data:image/png;base64,%@", [iconData base64EncodedStringWithOptions:0]];
    }
    PLProfiles.current.profiles[profileName] = profile;
    PLProfiles.current.selectedProfileName = profileName;
    [PLProfiles.current save];
}

@end
