#import "installer/FabricUtils.h"
#import "ModpackUtils.h"

static NSString * const EnhancedModpackErrorDomain = @"dev.amethyst.enhanced.modpack";

static void EnhancedSetModpackError(NSError *__autoreleasing *error, NSString *message) {
    if (!error) return;
    *error = [NSError errorWithDomain:EnhancedModpackErrorDomain
                                 code:400
                             userInfo:@{NSLocalizedDescriptionKey: message ?: @"Invalid modpack path"}];
}

static BOOL EnhancedSafeDestination(NSString *relative, NSString *root, NSString **destination) {
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

@implementation ModpackUtils

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError *__autoreleasing*)error {
    NSString *archivePrefix = [dir stringByAppendingString:@"/"];
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        NSString *archiveName = fileInfo.filename;
        if (![archiveName isKindOfClass:NSString.class] || ![archiveName hasPrefix:archivePrefix] ||
            archiveName.length <= archivePrefix.length) {
            return;
        }

        NSString *relative = [archiveName substringFromIndex:archivePrefix.length];
        NSString *destItemPath = nil;
        if (!EnhancedSafeDestination(relative, path, &destItemPath)) {
            EnhancedSetModpackError(error, [NSString stringWithFormat:@"Unsafe path blocked in modpack archive: %@", archiveName]);
            *stop = YES;
            return;
        }

        NSString *destDirPath = fileInfo.isDirectory ? destItemPath : destItemPath.stringByDeletingLastPathComponent;
        BOOL createdDir = [NSFileManager.defaultManager createDirectoryAtPath:destDirPath
            withIntermediateDirectories:YES
            attributes:nil error:error];
        if (!createdDir) {
            *stop = YES;
            return;
        } else if (fileInfo.isDirectory) {
            return;
        }

        NSData *data = [archive extractData:fileInfo error:error];
        BOOL written = data && [data writeToFile:destItemPath options:NSDataWritingAtomic error:error];
        *stop = !data || !written;
        if (!*stop) {
            NSLog(@"[ModpackDL] Extracted %@", archiveName);
        }
    } error:error];
}

+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency {
    NSMutableDictionary *info = [NSMutableDictionary new];
    NSString *minecraftVersion = dependency[@"minecraft"];
    if (dependency[@"forge"]) {
        info[@"id"] = [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, dependency[@"forge"]];
    } else if (dependency[@"fabric-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"fabric-loader-%@-%@", dependency[@"fabric-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Fabric"][@"json"], minecraftVersion, dependency[@"fabric-loader"]];
    } else if (dependency[@"quilt-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"quilt-loader-%@-%@", dependency[@"quilt-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Quilt"][@"json"], minecraftVersion, dependency[@"quilt-loader"]];
    }
    return info;
}

@end
