#import "WCRConfigStore.h"

#import "WCRContactName.h"

#import <AppKit/AppKit.h>

NSInteger const WCRConfigSchemaVersion = 1;
NSString *const WCRConfigDidImportNotification = @"WCRefineMacConfigDidImport";

static NSString *const kRevisionKey = @"WCRefineMacConfigRevision";
static const NSUInteger kMaxBackups = 8;

static NSString *SupportDirectory(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/WCRefine"];
}

static NSError *ConfigError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMacConfig"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"配置无效"}];
}

static BOOL PlistValue(id value) {
    if (!value || value == [NSNull null]) return NO;
    return [NSPropertyListSerialization dataWithPropertyList:value
                                                      format:NSPropertyListXMLFormat_v1_0
                                                     options:0
                                                       error:nil] != nil;
}

NSInteger WCRConfigStoreRevision(void) {
    return [[NSUserDefaults standardUserDefaults] integerForKey:kRevisionKey];
}

void WCRConfigStoreBumpRevision(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger revision = [defaults integerForKey:kRevisionKey];
    if (revision < 0) revision = 0;
    [defaults setInteger:revision + 1 forKey:kRevisionKey];
}

static NSDictionary *Preferences(void) {
    NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
    for (NSString *key in all) {
        if (![key isKindOfClass:[NSString class]] || ![key hasPrefix:@"WCRefineMac"]) continue;
        id value = all[key];
        if (!PlistValue(value)) continue;
        prefs[key] = value;
    }
    return prefs;
}

NSDictionary *WCRConfigStoreDocument(NSString *pluginVersion) {
    return @{
        @"schemaVersion": @(WCRConfigSchemaVersion),
        @"revision": @(WCRConfigStoreRevision()),
        @"pluginVersion": pluginVersion ?: @"",
        @"preferences": Preferences(),
        @"contacts": WCRContactNameRecords() ?: @[],
    };
}

static BOOL UserNameOK(NSString *userName) {
    if (userName.length < 5 || userName.length > 128) return NO;
    if ([userName isEqualToString:@"filehelper"]) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-@"];
    if ([userName rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;
    if ([userName containsString:@"@"]) {
        return [userName hasSuffix:@"@chatroom"] &&
               [[userName substringToIndex:userName.length - 9] rangeOfCharacterFromSet:
                    [NSCharacterSet decimalDigitCharacterSet].invertedSet].location == NSNotFound;
    }
    return YES;
}

static BOOL ValidateContacts(id contacts, NSError **error) {
    if (!contacts) return YES;
    if (![contacts isKindOfClass:[NSArray class]]) {
        if (error) *error = ConfigError(@"联系人缓存必须是数组");
        return NO;
    }
    if ([(NSArray *)contacts count] > 512) {
        if (error) *error = ConfigError(@"联系人缓存最多 512 条");
        return NO;
    }
    for (id item in (NSArray *)contacts) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            if (error) *error = ConfigError(@"联系人缓存里有无法识别的条目");
            return NO;
        }
        NSString *who = ((NSDictionary *)item)[@"userName"];
        if (![who isKindOfClass:[NSString class]] || !UserNameOK(who)) {
            if (error) *error = ConfigError(@"联系人缓存里有无效的用户名");
            return NO;
        }
        for (NSString *field in @[@"remark", @"groupNickname", @"nickname", @"alias"]) {
            id value = ((NSDictionary *)item)[field];
            if (value && ![value isKindOfClass:[NSString class]]) {
                if (error) *error = ConfigError(@"联系人缓存里有无效的名称字段");
                return NO;
            }
        }
    }
    return YES;
}

static BOOL ValidatePreferences(id prefs, NSError **error) {
    if (!prefs) return YES;
    if (![prefs isKindOfClass:[NSDictionary class]]) {
        if (error) *error = ConfigError(@"偏好必须是字典");
        return NO;
    }
    if ([(NSDictionary *)prefs count] > 200) {
        if (error) *error = ConfigError(@"偏好项过多");
        return NO;
    }
    for (id key in (NSDictionary *)prefs) {
        if (![key isKindOfClass:[NSString class]] || ![(NSString *)key hasPrefix:@"WCRefineMac"]) {
            if (error) *error = ConfigError(@"偏好里有不属于 WCRefine 的键");
            return NO;
        }
        id value = ((NSDictionary *)prefs)[key];
        if (value == [NSNull null]) continue;
        if (!PlistValue(value)) {
            if (error) *error = ConfigError([NSString stringWithFormat:@"偏好 %@ 的值无法保存", key]);
            return NO;
        }
    }
    return YES;
}

static BOOL BackupCurrent(NSError **error) {
    NSString *directory = [SupportDirectory() stringByAppendingPathComponent:@"backups"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"config-%@.plist", [formatter stringFromDate:[NSDate date]]];
    NSString *path = [directory stringByAppendingPathComponent:name];
    if ([fm fileExistsAtPath:path]) {
        path = [directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"config-%@-%u.plist",
                [formatter stringFromDate:[NSDate date]], arc4random_uniform(10000)]];
    }
    NSDictionary *document = WCRConfigStoreDocument(nil);
    if (![document writeToFile:path atomically:YES]) {
        if (error) *error = ConfigError(@"导入前备份失败，现有配置没有改动");
        return NO;
    }
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:directory error:nil] ?: @[];
    NSMutableArray<NSString *> *configs = [NSMutableArray array];
    for (NSString *item in names) {
        if ([item hasPrefix:@"config-"] && [item hasSuffix:@".plist"]) [configs addObject:item];
    }
    [configs sortUsingSelector:@selector(compare:)];
    while (configs.count > kMaxBackups) {
        [fm removeItemAtPath:[directory stringByAppendingPathComponent:configs.firstObject] error:nil];
        [configs removeObjectAtIndex:0];
    }
    return YES;
}

BOOL WCRConfigStoreImportDocument(NSDictionary *document, NSError **error) {
    if (![document isKindOfClass:[NSDictionary class]]) {
        if (error) *error = ConfigError(@"配置文件不是一份属性列表");
        return NO;
    }
    id schema = document[@"schemaVersion"];
    if (![schema isKindOfClass:[NSNumber class]] || [schema integerValue] != WCRConfigSchemaVersion) {
        if (error) *error = ConfigError(@"不认识这份配置的版本，现有配置没有改动");
        return NO;
    }
    id revision = document[@"revision"];
    if (revision && (![revision isKindOfClass:[NSNumber class]] || [revision integerValue] < 0 ||
                     [revision doubleValue] != [revision integerValue])) {
        if (error) *error = ConfigError(@"配置修订号无效，现有配置没有改动");
        return NO;
    }
    if (!ValidatePreferences(document[@"preferences"], error)) return NO;
    if (!ValidateContacts(document[@"contacts"], error)) return NO;
    if (!BackupCurrent(error)) return NO;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *prefs = [document[@"preferences"] isKindOfClass:[NSDictionary class]]
        ? document[@"preferences"] : nil;
    [prefs enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
        (void)stop;
        if (obj == [NSNull null]) [defaults removeObjectForKey:key];
        else [defaults setObject:obj forKey:key];
    }];
    if ([document[@"contacts"] isKindOfClass:[NSArray class]]) {
        WCRContactNameReplaceRecords(document[@"contacts"]);
    }
    if ([revision isKindOfClass:[NSNumber class]]) {
        [defaults setInteger:[revision integerValue] forKey:kRevisionKey];
    }
    WCRContactNameReloadStyle();
    return YES;
}

static void ShowAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = title;
        alert.informativeText = message ?: @"";
        [alert addButtonWithTitle:@"好"];
        [alert runModal];
    });
}

void WCRConfigStorePresentExport(NSString *pluginVersion) {
    NSString *version = [pluginVersion copy] ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.title = @"导出 WCRefine 配置";
        panel.nameFieldStringValue = @"WCRefine-config.plist";
        panel.canCreateDirectories = YES;
        [panel beginWithCompletionHandler:^(NSModalResponse result) {
            if (result != NSModalResponseOK || !panel.URL) return;
            NSDictionary *document = WCRConfigStoreDocument(version);
            if (![document writeToURL:panel.URL atomically:YES]) {
                ShowAlert(@"导出失败", @"配置文件没有写出去。");
            }
        }];
    });
}

void WCRConfigStorePresentImport(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = @"导入 WCRefine 配置";
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        [panel beginWithCompletionHandler:^(NSModalResponse result) {
            if (result != NSModalResponseOK || !panel.URL) return;
            NSDictionary *document = [NSDictionary dictionaryWithContentsOfURL:panel.URL];
            NSError *error = nil;
            if (!document) {
                ShowAlert(@"导入失败", @"这个文件不是一份属性列表，现有配置没有改动。");
                return;
            }
            if (!WCRConfigStoreImportDocument(document, &error)) {
                ShowAlert(@"导入失败", error.localizedDescription ?: @"现有配置没有改动。");
                return;
            }
            [[NSNotificationCenter defaultCenter]
                postNotificationName:WCRConfigDidImportNotification object:nil];
            ShowAlert(@"已导入配置", @"校验通过。导入前的配置已留在 WCRefine 的 backups 目录。");
        }];
    });
}
