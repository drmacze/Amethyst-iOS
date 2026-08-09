#import "AFNetworking.h"
#import "ContentHubViewController.h"
#import "DownloadProgressViewController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "UIKit+AFNetworking.h"
#import "content/EnhancedContentAPI.h"
#import "content/MinecraftResourceDownloadTask+Enhanced.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "installer/modpack/ModpackUtils.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface ContentHubViewController ()<UISearchResultsUpdating>
@property(nonatomic) UISearchController *searchController;
@property(nonatomic) UIButton *typeButton;
@property(nonatomic) UIButton *providerButton;
@property(nonatomic) UILabel *profileLabel;
@property(nonatomic) NSMutableArray<NSMutableDictionary *> *items;
@property(nonatomic) EnhancedContentAPI *api;
@property(nonatomic) EnhancedContentType contentType;
@property(nonatomic) EnhancedContentProvider provider;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL reachedLastPage;
@property(nonatomic) NSString *lastQuery;
@property(nonatomic) NSString *lastGameDir;
@end

@implementation ContentHubViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"Content Hub";
        _contentType = EnhancedContentTypeShader;
        _provider = EnhancedContentProviderModrinth;
        _api = [[EnhancedContentAPI alloc] initWithProvider:_provider];
        _items = [NSMutableArray new];
    }
    return self;
}

- (NSString *)imageName {
    return @"square.grid.2x2";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search community content";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    [self buildHeader];
    [self buildNavigationItems];
    [self refreshHeader];
    [self reloadFromStart];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationItem.leftBarButtonItem = self.splitViewController.displayModeButtonItem;
    self.navigationItem.rightItemsSupplementBackButton = YES;
    [self refreshHeader];
    NSString *gameDir = [EnhancedContentAPI currentGameDirectory];
    if (self.lastGameDir && ![self.lastGameDir isEqualToString:gameDir]) {
        [self reloadFromStart];
    }
    self.lastGameDir = gameDir;
}

#pragma mark - Header and menus

- (UIButton *)menuButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, 160, 34);
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [button setTitle:title forState:UIControlStateNormal];
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *config = [UIButtonConfiguration tintedButtonConfiguration];
        config.cornerStyle = UIButtonConfigurationCornerStyleMedium;
        config.image = [UIImage systemImageNamed:@"chevron.down"];
        config.imagePlacement = NSDirectionalRectEdgeTrailing;
        config.imagePadding = 8;
        config.title = title;
        button.configuration = config;
    }
    button.showsMenuAsPrimaryAction = YES;
    return button;
}

- (void)buildHeader {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 106)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    self.profileLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, 100, 34)];
    self.profileLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.profileLabel.textColor = UIColor.secondaryLabelColor;
    self.profileLabel.numberOfLines = 2;
    self.profileLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:self.profileLabel];

    self.typeButton = [self menuButtonWithTitle:@"Shaders"];
    self.typeButton.frame = CGRectMake(16, 55, 155, 36);
    [header addSubview:self.typeButton];

    self.providerButton = [self menuButtonWithTitle:@"Modrinth"];
    self.providerButton.frame = CGRectMake(182, 55, 155, 36);
    self.providerButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [header addSubview:self.providerButton];

    self.tableView.tableHeaderView = header;
    [self rebuildMenus];
}

- (void)buildNavigationItems {
    UIBarButtonItem *account = [sidebarViewController drawAccountButton];
    UIBarButtonItem *actions = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[self actionsMenu]];
    self.navigationItem.rightBarButtonItems = @[account, actions];
}

- (UIMenu *)actionsMenu {
    __weak ContentHubViewController *weakSelf = self;
    UIAction *importURL = [UIAction actionWithTitle:@"Install from URL" image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(UIAction *action) {
        [weakSelf promptImportURL];
    }];
    UIAction *installed = [UIAction actionWithTitle:@"Installed by Content Hub" image:[UIImage systemImageNamed:@"tray.full"] identifier:nil handler:^(UIAction *action) {
        [weakSelf showInstalledContent];
    }];
    UIAction *cfKey = [UIAction actionWithTitle:@"CurseForge API Key" image:[UIImage systemImageNamed:@"key"] identifier:nil handler:^(UIAction *action) {
        [weakSelf promptCurseForgeKey];
    }];
    UIAction *refresh = [UIAction actionWithTitle:@"Refresh" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *action) {
        [weakSelf reloadFromStart];
    }];
    return [UIMenu menuWithTitle:@"Content Hub" children:@[importURL, installed, cfKey, refresh]];
}

- (void)rebuildMenus {
    __weak ContentHubViewController *weakSelf = self;
    NSMutableArray<UIMenuElement *> *types = [NSMutableArray new];
    for (NSInteger i = EnhancedContentTypeMod; i <= EnhancedContentTypeWorld; i++) {
        EnhancedContentType type = (EnhancedContentType)i;
        UIAction *action = [UIAction actionWithTitle:[EnhancedContentAPI nameForType:type]
                                               image:nil
                                          identifier:nil
                                             handler:^(UIAction *action) {
            weakSelf.contentType = type;
            [weakSelf refreshHeader];
            [weakSelf rebuildMenus];
            [weakSelf reloadFromStart];
        }];
        action.state = type == self.contentType ? UIMenuElementStateOn : UIMenuElementStateOff;
        [types addObject:action];
    }
    self.typeButton.menu = [UIMenu menuWithTitle:@"Content type" children:types];

    NSMutableArray<UIMenuElement *> *providers = [NSMutableArray new];
    for (NSInteger i = EnhancedContentProviderModrinth; i <= EnhancedContentProviderCurseForge; i++) {
        EnhancedContentProvider provider = (EnhancedContentProvider)i;
        UIAction *action = [UIAction actionWithTitle:[EnhancedContentAPI nameForProvider:provider]
                                               image:nil
                                          identifier:nil
                                             handler:^(UIAction *action) {
            [weakSelf selectProvider:provider];
        }];
        action.state = provider == self.provider ? UIMenuElementStateOn : UIMenuElementStateOff;
        [providers addObject:action];
    }
    self.providerButton.menu = [UIMenu menuWithTitle:@"Provider" children:providers];
}

- (void)selectProvider:(EnhancedContentProvider)provider {
    EnhancedContentAPI *candidate = [[EnhancedContentAPI alloc] initWithProvider:provider];
    if (![candidate isAvailable]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"CurseForge API key required"
                                                                       message:candidate.availabilityMessage
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Add Key" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self promptCurseForgeKey];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    self.provider = provider;
    self.api = candidate;
    [self refreshHeader];
    [self rebuildMenus];
    [self reloadFromStart];
}

- (void)refreshHeader {
    NSString *version = [EnhancedContentAPI currentMinecraftVersion];
    NSString *loader = [EnhancedContentAPI currentModLoader];
    NSString *profile = PLProfiles.current.selectedProfileName ?: @"(Default)";
    self.profileLabel.text = [NSString stringWithFormat:@"Install target: %@  •  Minecraft %@%@",
                              profile, version.length ? version : @"unknown",
                              loader.length ? [NSString stringWithFormat:@"  •  %@", loader.capitalizedString] : @""];
    NSString *typeName = [EnhancedContentAPI nameForType:self.contentType];
    NSString *providerName = [EnhancedContentAPI nameForProvider:self.provider];
    [self.typeButton setTitle:typeName forState:UIControlStateNormal];
    [self.providerButton setTitle:providerName forState:UIControlStateNormal];
    if (@available(iOS 15.0, *)) {
        self.typeButton.configuration.title = typeName;
        self.providerButton.configuration.title = providerName;
    }
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reloadFromStart) object:nil];
    [self performSelector:@selector(reloadFromStart) withObject:nil afterDelay:0.35];
}

- (void)reloadFromStart {
    if (self.loading) return;
    self.reachedLastPage = NO;
    self.lastQuery = self.searchController.searchBar.text ?: @"";
    [self loadPageAtOffset:0 replace:YES];
}

- (void)loadNextPage {
    if (self.loading || self.reachedLastPage) return;
    [self loadPageAtOffset:self.items.count replace:NO];
}

- (void)loadPageAtOffset:(NSUInteger)offset replace:(BOOL)replace {
    self.loading = YES;
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [indicator startAnimating];
    self.navigationItem.titleView = indicator;

    NSString *query = replace ? (self.searchController.searchBar.text ?: @"") : self.lastQuery;
    NSString *mcVersion = [EnhancedContentAPI currentMinecraftVersion];
    NSString *loader = [EnhancedContentAPI currentModLoader];
    EnhancedContentType type = self.contentType;
    EnhancedContentAPI *api = self.api;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *results = [api searchType:type query:query minecraftVersion:mcVersion loader:loader offset:offset];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loading = NO;
            self.navigationItem.titleView = nil;
            self.title = @"Content Hub";
            if (!results) {
                NSString *message = api.lastError.localizedDescription ?: @"Could not load content.";
                [self showError:message];
                return;
            }
            if (replace) {
                self.items = results.mutableCopy;
                self.lastQuery = query;
            } else {
                [self.items addObjectsFromArray:results];
            }
            self.reachedLastPage = api.reachedLastPage;
            [self.tableView reloadData];
        });
    });
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.items.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ContentCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ContentCell"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
        cell.imageView.clipsToBounds = YES;
    }
    NSDictionary *item = self.items[indexPath.row];
    cell.textLabel.text = item[@"title"];
    NSNumber *downloads = item[@"downloads"];
    NSString *detail = item[@"description"] ?: @"";
    if (downloads.unsignedLongLongValue > 0) {
        NSNumberFormatter *formatter = [NSNumberFormatter new];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        detail = [NSString stringWithFormat:@"%@ downloads  •  %@", [formatter stringFromNumber:downloads], detail];
    }
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.numberOfLines = 2;
    NSURL *iconURL = [NSURL URLWithString:item[@"imageUrl"] ?: @""];
    [cell.imageView setImageWithURL:iconURL placeholderImage:[UIImage systemImageNamed:@"shippingbox"]];

    if (!self.reachedLastPage && indexPath.row >= (NSInteger)self.items.count - 4) [self loadNextPage];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = self.items[indexPath.row];
    [self loadVersionsForItem:item];
}

#pragma mark - Versions and installation

- (void)loadVersionsForItem:(NSDictionary *)item {
    self.loading = YES;
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [indicator startAnimating];
    self.navigationItem.titleView = indicator;
    NSString *mcVersion = [EnhancedContentAPI currentMinecraftVersion];
    NSString *loader = [EnhancedContentAPI currentModLoader];
    EnhancedContentAPI *api = self.api;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *versions = [api versionsForItem:item minecraftVersion:mcVersion loader:loader];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loading = NO;
            self.navigationItem.titleView = nil;
            self.title = @"Content Hub";
            if (!versions) {
                [self showError:api.lastError.localizedDescription ?: @"Could not load versions."];
                return;
            }
            if (versions.count == 0) {
                [self showError:@"No downloadable files matched the selected Minecraft version/provider rules."];
                return;
            }
            [self presentVersions:versions item:item];
        });
    });
}

- (void)presentVersions:(NSArray<NSDictionary *> *)versions item:(NSDictionary *)item {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:item[@"title"]
                                                                   message:@"Choose a compatible file to install"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger limit = MIN(versions.count, 50);
    for (NSUInteger i = 0; i < limit; i++) {
        NSDictionary *version = versions[i];
        NSString *label = version[@"name"] ?: version[@"filename"];
        NSArray *gameVersions = version[@"gameVersions"];
        NSArray *loaders = version[@"loaders"];
        NSMutableArray *suffix = [NSMutableArray new];
        if (gameVersions.count) [suffix addObject:[[gameVersions subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)2, gameVersions.count))] componentsJoinedByString:@", "]];
        if (loaders.count) [suffix addObject:[[loaders subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)2, loaders.count))] componentsJoinedByString:@", "]];
        if (suffix.count) label = [label stringByAppendingFormat:@" — %@", [suffix componentsJoinedByString:@" • "]];
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self installVersion:version item:item];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (NSString *)folderForType:(EnhancedContentType)type {
    switch (type) {
        case EnhancedContentTypeMod: return @"mods";
        case EnhancedContentTypeResourcePack: return @"resourcepacks";
        case EnhancedContentTypeShader: return @"shaderpacks";
        case EnhancedContentTypeWorld: return @"saves";
        case EnhancedContentTypeModpack: return @"";
    }
}

- (NSString *)safeFileComponent:(NSString *)input fallback:(NSString *)fallback {
    NSMutableString *output = [NSMutableString new];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_. "];
    for (NSUInteger i = 0; i < input.length; i++) {
        unichar c = [input characterAtIndex:i];
        [output appendString:[allowed characterIsMember:c] ? [NSString stringWithCharacters:&c length:1] : @"_"];
    }
    NSString *trimmed = [output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length ? trimmed : fallback;
}

- (void)installVersion:(NSDictionary *)version item:(NSDictionary *)item {
    EnhancedContentType type = [item[@"type"] integerValue];
    EnhancedContentProvider provider = [item[@"provider"] integerValue];
    if (type == EnhancedContentTypeModpack) {
        [self installModpackVersion:version item:item provider:provider];
        return;
    }

    NSString *filename = [self safeFileComponent:version[@"filename"] ?: @"download" fallback:@"download"];
    NSString *gameDir = [EnhancedContentAPI currentGameDirectory];
    NSString *folder = [self folderForType:type];
    NSString *destination = [[gameDir stringByAppendingPathComponent:folder] stringByAppendingPathComponent:filename];
    NSString *downloadDestination = destination;
    if (type == EnhancedContentTypeWorld) {
        downloadDestination = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"amethyst-world-%@.zip", NSUUID.UUID.UUIDString]];
    }

    if (![self validateFilename:filename forType:type]) {
        [self showError:[NSString stringWithFormat:@"The selected file (%@) has an unexpected extension for %@.", filename, [EnhancedContentAPI nameForType:type]]];
        return;
    }

    MinecraftResourceDownloadTask *task = [MinecraftResourceDownloadTask new];
    task.handleError = ^{};
    __weak ContentHubViewController *weakSelf = self;
    [task enhancedDownloadURL:version[@"url"]
                         size:[version[@"size"] unsignedLongLongValue]
                         sha1:version[@"sha1"]
                  displayName:filename
                       toPath:downloadDestination
                   completion:^(NSString *path) {
        if (type == EnhancedContentTypeWorld) {
            [weakSelf installWorldArchive:path item:item version:version];
        } else {
            [weakSelf recordInstalledItem:item version:version path:destination];
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf showSuccess:[NSString stringWithFormat:@"Installed %@ into %@.", filename, folder]];
            });
        }
    }];
    [self presentDownloadTask:task title:item[@"title"]];
}

- (BOOL)validateFilename:(NSString *)filename forType:(EnhancedContentType)type {
    NSString *ext = filename.pathExtension.lowercaseString;
    if (type == EnhancedContentTypeMod) return [ext isEqualToString:@"jar"];
    if (type == EnhancedContentTypeShader || type == EnhancedContentTypeResourcePack || type == EnhancedContentTypeWorld) return [ext isEqualToString:@"zip"];
    return YES;
}

- (void)installModpackVersion:(NSDictionary *)version item:(NSDictionary *)item provider:(EnhancedContentProvider)provider {
    NSMutableDictionary *detail = [item mutableCopy];
    detail[@"versionUrls"] = @[version[@"url"] ?: @""];
    detail[@"versionSizes"] = @[version[@"size"] ?: @0];
    detail[@"versionHashes"] = @[version[@"sha1"] ?: @""];
    detail[@"versionNames"] = @[version[@"name"] ?: @"Version"];
    detail[@"mcVersionNames"] = @[[EnhancedContentAPI currentMinecraftVersion] ?: @""];

    ModpackAPI *modpackAPI = provider == EnhancedContentProviderCurseForge ? [CurseForgeAPI new] : [ModrinthAPI new];
    if (provider == EnhancedContentProviderCurseForge && ![(CurseForgeAPI *)modpackAPI respondsToSelector:@selector(downloader:submitDownloadTasksFromPackage:toPath:)]) {
        [self showError:@"CurseForge modpack installation is unavailable in this build."];
        return;
    }
    MinecraftResourceDownloadTask *task = [MinecraftResourceDownloadTask new];
    task.handleError = ^{};
    [task downloadModpackFromAPI:modpackAPI detail:detail atIndex:0];
    [self presentDownloadTask:task title:item[@"title"]];
}

- (void)presentDownloadTask:(MinecraftResourceDownloadTask *)task title:(NSString *)title {
    DownloadProgressViewController *progress = [[DownloadProgressViewController alloc] initWithTask:task];
    progress.title = title;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:progress];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - World extraction

- (void)installWorldArchive:(NSString *)archivePath item:(NSDictionary *)item version:(NSDictionary *)version {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        UZKArchive *archive = [[UZKArchive alloc] initWithPath:archivePath error:&error];
        if (!archive || error) {
            [self finishWorldInstallWithError:error.localizedDescription ?: @"Could not open the world ZIP."];
            return;
        }

        NSMutableArray<NSString *> *names = [NSMutableArray new];
        [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
            if (fileInfo.filename.length) [names addObject:fileInfo.filename];
        } error:&error];
        if (error || names.count == 0) {
            [self finishWorldInstallWithError:error.localizedDescription ?: @"The world ZIP is empty."];
            return;
        }

        NSString *commonRoot = [self commonArchiveRoot:names];
        NSString *safeTitle = [self safeFileComponent:item[@"title"] ?: @"World" fallback:@"World"];
        NSString *saves = [[EnhancedContentAPI currentGameDirectory] stringByAppendingPathComponent:@"saves"];
        NSString *worldPath = [self uniqueDirectory:[saves stringByAppendingPathComponent:safeTitle]];
        if (![NSFileManager.defaultManager createDirectoryAtPath:worldPath withIntermediateDirectories:YES attributes:nil error:&error]) {
            [self finishWorldInstallWithError:error.localizedDescription];
            return;
        }
        NSString *rootPrefix = [worldPath.stringByStandardizingPath stringByAppendingString:@"/"];

        __block BOOL unsafe = NO;
        [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
            NSString *relative = fileInfo.filename;
            if (commonRoot.length && [relative hasPrefix:[commonRoot stringByAppendingString:@"/"]]) {
                relative = [relative substringFromIndex:commonRoot.length + 1];
            }
            if (relative.length == 0) return;
            NSArray *components = relative.pathComponents;
            if ([relative hasPrefix:@"/"] || [components containsObject:@".."] || [components containsObject:@"~"]) {
                unsafe = YES; *stop = YES; return;
            }
            NSString *dest = [[worldPath stringByAppendingPathComponent:relative] stringByStandardizingPath];
            if (![dest hasPrefix:rootPrefix]) { unsafe = YES; *stop = YES; return; }
            if (fileInfo.isDirectory) {
                [NSFileManager.defaultManager createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:&error];
            } else {
                [NSFileManager.defaultManager createDirectoryAtPath:dest.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];
                NSData *data = [archive extractData:fileInfo error:&error];
                if (!error && data) [data writeToFile:dest options:NSDataWritingAtomic error:&error];
            }
            if (error) *stop = YES;
        } error:&error];

        [NSFileManager.defaultManager removeItemAtPath:archivePath error:nil];
        if (unsafe || error) {
            [NSFileManager.defaultManager removeItemAtPath:worldPath error:nil];
            [self finishWorldInstallWithError:unsafe ? @"Unsafe path detected inside the world ZIP; extraction was blocked." : error.localizedDescription];
            return;
        }
        [self recordInstalledItem:item version:version path:worldPath];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showSuccess:[NSString stringWithFormat:@"World installed as %@.", worldPath.lastPathComponent]];
        });
    });
}

- (NSString *)commonArchiveRoot:(NSArray<NSString *> *)names {
    NSString *root = nil;
    for (NSString *name in names) {
        NSArray *parts = name.pathComponents;
        if (parts.count < 2) return nil;
        NSString *first = parts.firstObject;
        if (!root) root = first;
        else if (![root isEqualToString:first]) return nil;
    }
    return root;
}

- (NSString *)uniqueDirectory:(NSString *)base {
    if (![NSFileManager.defaultManager fileExistsAtPath:base]) return base;
    for (NSInteger i = 2; i < 10000; i++) {
        NSString *candidate = [base stringByAppendingFormat:@" %ld", (long)i];
        if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) return candidate;
    }
    return [base stringByAppendingFormat:@" %@", NSUUID.UUID.UUIDString];
}

- (void)finishWorldInstallWithError:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{ [self showError:message ?: @"World installation failed."]; });
}

#pragma mark - Content registry / management

- (NSString *)registryPath {
    return [[[EnhancedContentAPI currentGameDirectory] stringByAppendingPathComponent:@".amethyst"] stringByAppendingPathComponent:@"content-index.json"];
}

- (NSMutableDictionary *)loadRegistry {
    NSMutableDictionary *registry = parseJSONFromFile(self.registryPath);
    if (![registry isKindOfClass:NSMutableDictionary.class] || registry[@"NSErrorObject"]) {
        registry = [@{@"schema":@1, @"items":[NSMutableArray new]} mutableCopy];
    }
    if (![registry[@"items"] isKindOfClass:NSMutableArray.class]) registry[@"items"] = [NSMutableArray new];
    return registry;
}

- (void)recordInstalledItem:(NSDictionary *)item version:(NSDictionary *)version path:(NSString *)path {
    if (!path.length) return;
    @synchronized (ContentHubViewController.class) {
        NSMutableDictionary *registry = [self loadRegistry];
        NSMutableArray *records = registry[@"items"];
        NSIndexSet *old = [records indexesOfObjectsPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop) {
            return [obj[@"path"] isEqualToString:path];
        }];
        [records removeObjectsAtIndexes:old];
        [records addObject:@{
            @"provider":item[@"provider"] ?: @0,
            @"type":item[@"type"] ?: @0,
            @"projectId":[item[@"id"] description] ?: @"",
            @"title":item[@"title"] ?: path.lastPathComponent,
            @"version":version[@"versionNumber"] ?: version[@"name"] ?: @"",
            @"filename":version[@"filename"] ?: path.lastPathComponent,
            @"path":path,
            @"installedAt":@((long long)NSDate.date.timeIntervalSince1970)
        }];
        [NSFileManager.defaultManager createDirectoryAtPath:self.registryPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        saveJSONToFile(registry, self.registryPath);
    }
}

- (void)showInstalledContent {
    NSMutableDictionary *registry = [self loadRegistry];
    NSArray *records = registry[@"items"];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Installed by Content Hub"
                                                                   message:records.count ? @"Tap an entry to remove its installed file/folder." : @"No Content Hub installs are recorded for this profile."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *record in [records reverseObjectEnumerator]) {
        NSString *title = [NSString stringWithFormat:@"%@ — %@", record[@"title"], record[@"version"] ?: @""];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self confirmRemoveRecord:record];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmRemoveRecord:(NSDictionary *)record {
    NSString *path = record[@"path"];
    NSString *gameDirPrefix = [[EnhancedContentAPI currentGameDirectory].stringByStandardizingPath stringByAppendingString:@"/"];
    NSString *standard = path.stringByStandardizingPath;
    if (![standard hasPrefix:gameDirPrefix]) {
        [self showError:@"Refusing to delete a path outside the selected Minecraft profile directory."];
        return;
    }
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Remove installed content?"
                                                                     message:standard
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSError *error = nil;
        [NSFileManager.defaultManager removeItemAtPath:standard error:&error];
        if (error && error.code != NSFileNoSuchFileError) { [self showError:error.localizedDescription]; return; }
        NSMutableDictionary *registry = [self loadRegistry];
        NSMutableArray *items = registry[@"items"];
        [items filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *obj, NSDictionary *bindings) {
            return ![obj[@"path"] isEqualToString:path];
        }]];
        saveJSONToFile(registry, self.registryPath);
        [self showSuccess:@"Removed Content Hub installation."];
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

#pragma mark - URL import and provider settings

- (void)promptImportURL {
    if (self.contentType == EnhancedContentTypeModpack) {
        [self showError:@"Direct URL import for modpacks is intentionally disabled because a modpack requires dependency/profile processing. Use the Modrinth or CurseForge provider instead."];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Install %@ from URL", [EnhancedContentAPI nameForType:self.contentType]]
                                                                   message:@"Paste a direct HTTPS file URL. The file will be installed into the selected profile automatically."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"https://…/file.zip";
        textField.keyboardType = UIKeyboardTypeURL;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Install" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *urlString = alert.textFields.firstObject.text;
        NSURL *url = [NSURL URLWithString:urlString];
        if (![url.scheme.lowercaseString isEqualToString:@"https"] || url.lastPathComponent.length == 0) {
            [self showError:@"Use a valid direct HTTPS URL."];
            return;
        }
        NSString *filename = [self safeFileComponent:url.lastPathComponent fallback:@"download"];
        if (![self validateFilename:filename forType:self.contentType]) {
            [self showError:@"The URL filename extension does not match the selected content type."];
            return;
        }
        NSDictionary *item = @{@"provider":@(-1), @"type":@(self.contentType), @"id":urlString, @"title":filename};
        NSDictionary *version = @{@"name":@"Direct URL", @"versionNumber":@"direct", @"filename":filename, @"url":urlString, @"size":@0, @"sha1":@""};
        [self installVersion:version item:item];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptCurseForgeKey {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"CurseForge API Key"
                                                                   message:@"CurseForge requires an approved x-api-key for third-party launchers. The key is stored only in this launcher's preferences and is never logged. Leave empty to remove it."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"x-api-key";
        textField.secureTextEntry = YES;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *key = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        setPrefObject(@"content.curseforge_api_key", key ?: @"");
        self.api = [[EnhancedContentAPI alloc] initWithProvider:self.provider];
        [self rebuildMenus];
        if (self.provider == EnhancedContentProviderCurseForge && ![self.api isAvailable]) {
            self.provider = EnhancedContentProviderModrinth;
            self.api = [[EnhancedContentAPI alloc] initWithProvider:self.provider];
        }
        [self refreshHeader];
        [self rebuildMenus];
        [self reloadFromStart];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Dialogs

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Content Hub" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showSuccess:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Installed" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
