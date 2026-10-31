#import "WCRContactName.h"

#import <os/log.h>

#include <atomic>
#include <mutex>

static NSString *const kStyleKey = @"WCRefineMacContactNameStyle";
static NSString *const kNotifyKey = @"WCRefineMacNotifyContactsEnabled";
static NSString *const kNotifyIDsKey = @"WCRefineMacNotifyContactIDs";
static const NSUInteger kMaxRecords = 512;
static const NSUInteger kMaxNotify = 8;

static os_log_t NameLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.wcrefine.mac", "contact-name");
    });
    return log;
}

static std::mutex gLock;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *gRecords;
static std::atomic<int> gStyle{WCRContactNameStyleAuto};
static std::atomic<bool> gStyleReady{false};
static std::atomic<bool> gLoaded{false};
static BOOL gTesting = NO;

static NSString *Trim(NSString *value) {
    NSString *text = [value stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    if (text.length > 128) text = [text substringToIndex:128];
    return text;
}

static NSString *NonEmpty(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *text = Trim((NSString *)value);
    return text.length ? text : nil;
}

static BOOL HostIsWeChat(void) {
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier ?: @"";
    return [bundleID isEqualToString:@"com.tencent.xinWeChat"] ||
           [bundleID hasPrefix:@"com.tencent.xinWeChat.WCRefineMulti"];
}

static NSString *StorePath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/WCRefine"]
        stringByAppendingPathComponent:@"contact-names.plist"];
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

static void LoadLocked(void) {
    if (gLoaded.load(std::memory_order_acquire) || gTesting) {
        if (!gRecords) gRecords = [NSMutableDictionary dictionary];
        return;
    }
    gRecords = [NSMutableDictionary dictionary];
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:StorePath()];
    NSDictionary *records = [stored isKindOfClass:[NSDictionary class]] ? stored[@"records"] : nil;
    if ([records isKindOfClass:[NSDictionary class]]) {
        [records enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            (void)stop;
            if (![key isKindOfClass:[NSString class]] || !UserNameOK(key)) return;
            if (![obj isKindOfClass:[NSDictionary class]]) return;
            NSMutableDictionary *row = [NSMutableDictionary dictionary];
            for (NSString *field in @[@"remark", @"groupNickname", @"nickname", @"alias"]) {
                NSString *text = NonEmpty(obj[field]);
                if (text) row[field] = text;
            }
            if ([obj[@"updated"] isKindOfClass:[NSNumber class]]) row[@"updated"] = obj[@"updated"];
            if (row.count) gRecords[key] = row;
        }];
    }
    gLoaded.store(true, std::memory_order_release);
}

static void SaveLocked(void) {
    if (gTesting || !HostIsWeChat()) return;
    NSString *path = StorePath();
    NSString *directory = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSMutableDictionary *records = [NSMutableDictionary dictionaryWithCapacity:gRecords.count];
    [gRecords enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSMutableDictionary *obj, BOOL *stop) {
        (void)stop;
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        for (NSString *field in @[@"remark", @"groupNickname", @"nickname", @"alias"]) {
            NSString *text = NonEmpty(obj[field]);
            if (text) row[field] = text;
        }
        if ([obj[@"updated"] isKindOfClass:[NSNumber class]]) row[@"updated"] = obj[@"updated"];
        if (row.count) records[key] = row;
    }];
    NSDictionary *document = @{@"records": records};
    if (![document writeToFile:path atomically:YES]) {
        os_log_error(NameLog(), "contact name cache write failed");
    }
}

static void TrimLocked(void) {
    if (gRecords.count <= kMaxRecords) return;
    NSArray *keys = [gRecords keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double left = [a[@"updated"] doubleValue];
        double right = [b[@"updated"] doubleValue];
        if (left < right) return NSOrderedAscending;
        if (left > right) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSUInteger extra = gRecords.count - kMaxRecords;
    for (NSUInteger index = 0; index < extra && index < keys.count; ++index) {
        [gRecords removeObjectForKey:keys[index]];
    }
}

static void MergeLocked(NSString *userName,
                        NSString *remark,
                        NSString *groupNickname,
                        NSString *nickname,
                        NSString *alias) {
    LoadLocked();
    NSMutableDictionary *row = gRecords[userName];
    if (!row) row = [NSMutableDictionary dictionary];
    BOOL changed = NO;
    NSString *fields[] = {remark, groupNickname, nickname, alias};
    NSString *keys[] = {@"remark", @"groupNickname", @"nickname", @"alias"};
    for (int index = 0; index < 4; ++index) {
        NSString *text = NonEmpty(fields[index]);
        if (!text || [text isEqualToString:userName] || [text isEqualToString:@"未知用户"]) continue;
        if ([row[keys[index]] isEqualToString:text]) continue;
        row[keys[index]] = text;
        changed = YES;
    }
    if (!changed && gRecords[userName]) return;
    if (row.count == 0) return;
    row[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
    gRecords[userName] = row;
    TrimLocked();
    SaveLocked();
}

static NSString *First(NSArray<NSString *> *values) {
    for (NSString *value in values) {
        NSString *text = NonEmpty(value);
        if (text) return text;
    }
    return @"";
}

static WCRContactNameStyle LoadStyle(void) {
    if (gStyleReady.load(std::memory_order_acquire)) {
        return (WCRContactNameStyle)gStyle.load(std::memory_order_relaxed);
    }
    NSInteger raw = [[NSUserDefaults standardUserDefaults] integerForKey:kStyleKey];
    if (raw < WCRContactNameStyleAuto || raw > WCRContactNameStyleWxid) raw = WCRContactNameStyleAuto;
    gStyle.store((int)raw, std::memory_order_relaxed);
    gStyleReady.store(true, std::memory_order_release);
    return (WCRContactNameStyle)raw;
}

static NSString *Pick(WCRContactNameStyle style,
                      NSString *userName,
                      NSString *remark,
                      NSString *groupNickname,
                      NSString *nickname,
                      NSString *alias,
                      NSString *observed) {
    NSString *seen = NonEmpty(observed);
    NSString *who = NonEmpty(userName);
    switch (style) {
        case WCRContactNameStyleRemark:
            return First(@[remark ?: @"", seen ?: @"", groupNickname ?: @"", nickname ?: @"", alias ?: @"", who ?: @""]);
        case WCRContactNameStyleGroupNickname:
            return First(@[groupNickname ?: @"", seen ?: @"", remark ?: @"", nickname ?: @"", alias ?: @"", who ?: @""]);
        case WCRContactNameStyleNickname:
            return First(@[nickname ?: @"", seen ?: @"", remark ?: @"", groupNickname ?: @"", alias ?: @"", who ?: @""]);
        case WCRContactNameStyleAlias:
            return First(@[alias ?: @"", seen ?: @"", remark ?: @"", groupNickname ?: @"", nickname ?: @"", who ?: @""]);
        case WCRContactNameStyleWxid:
            return who ?: (seen ?: @"");
        case WCRContactNameStyleAuto:
        default:
            // 这次看到的名字先于群名片和 wxid，避免把「张三撤回了」换成用户名。
            return First(@[remark ?: @"", seen ?: @"", groupNickname ?: @"", nickname ?: @"", alias ?: @"", who ?: @""]);
    }
}

WCRContactNameStyle WCRContactNameCurrentStyle(void) {
    return LoadStyle();
}

void WCRContactNameReloadStyle(void) {
    if (gTesting) return;
    gStyleReady.store(false, std::memory_order_release);
}

void WCRContactNameSetStyle(WCRContactNameStyle style) {
    if (style < WCRContactNameStyleAuto || style > WCRContactNameStyleWxid) {
        style = WCRContactNameStyleAuto;
    }
    gStyle.store((int)style, std::memory_order_relaxed);
    gStyleReady.store(true, std::memory_order_release);
    if (gTesting) return;
    [[NSUserDefaults standardUserDefaults] setInteger:style forKey:kStyleKey];
}

NSString *WCRContactNamePreferred(NSString *userName, NSString *observed) {
    return WCRContactNameResolve(userName, nil, nil, observed);
}

NSString *WCRContactNameResolve(NSString *userName,
                                NSString *groupNickname,
                                NSString *nickname,
                                NSString *observed) {
    NSString *who = NonEmpty(userName);
    NSString *remark = nil;
    NSString *group = NonEmpty(groupNickname);
    NSString *nick = NonEmpty(nickname);
    NSString *alias = nil;
    if (who) {
        std::lock_guard<std::mutex> lock(gLock);
        LoadLocked();
        NSDictionary *row = gRecords[who];
        remark = NonEmpty(row[@"remark"]);
        if (!group) group = NonEmpty(row[@"groupNickname"]);
        if (!nick) nick = NonEmpty(row[@"nickname"]);
        alias = NonEmpty(row[@"alias"]);
    }
    return Pick(LoadStyle(), who, remark, group, nick, alias, observed);
}

void WCRContactNameRemember(NSString *userName,
                            NSString *remark,
                            NSString *groupNickname,
                            NSString *nickname,
                            NSString *alias) {
    NSString *who = NonEmpty(userName);
    if (!UserNameOK(who) || gTesting || !HostIsWeChat()) return;
    std::lock_guard<std::mutex> lock(gLock);
    MergeLocked(who, remark, groupNickname, nickname, alias);
}

NSString *WCRContactNameDisplay(NSString *userName) {
    NSString *who = NonEmpty(userName);
    if (!who) return @"";
    std::lock_guard<std::mutex> lock(gLock);
    LoadLocked();
    NSDictionary *row = gRecords[who];
    return First(@[
        NonEmpty(row[@"remark"]) ?: @"",
        NonEmpty(row[@"groupNickname"]) ?: @"",
        NonEmpty(row[@"nickname"]) ?: @"",
        NonEmpty(row[@"alias"]) ?: @"",
        who,
    ]);
}

NSArray<NSDictionary<NSString *, NSString *> *> *WCRContactNameRecords(void) {
    std::lock_guard<std::mutex> lock(gLock);
    LoadLocked();
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:gRecords.count];
    [gRecords enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSMutableDictionary *obj, BOOL *stop) {
        (void)stop;
        NSMutableDictionary<NSString *, NSString *> *row = [NSMutableDictionary dictionary];
        row[@"userName"] = key;
        for (NSString *field in @[@"remark", @"groupNickname", @"nickname", @"alias"]) {
            NSString *text = NonEmpty(obj[field]);
            if (text) row[field] = text;
        }
        [rows addObject:row];
    }];
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        // 这里已经拿着 gLock。Display 会再锁一次，不能从比较器里调用。
        NSString *left = First(@[
            NonEmpty(a[@"remark"]) ?: @"",
            NonEmpty(a[@"groupNickname"]) ?: @"",
            NonEmpty(a[@"nickname"]) ?: @"",
            NonEmpty(a[@"alias"]) ?: @"",
            NonEmpty(a[@"userName"]) ?: @"",
        ]);
        NSString *right = First(@[
            NonEmpty(b[@"remark"]) ?: @"",
            NonEmpty(b[@"groupNickname"]) ?: @"",
            NonEmpty(b[@"nickname"]) ?: @"",
            NonEmpty(b[@"alias"]) ?: @"",
            NonEmpty(b[@"userName"]) ?: @"",
        ]);
        return [left localizedStandardCompare:right];
    }];
    return rows;
}

void WCRContactNameReplaceRecords(NSArray<NSDictionary<NSString *, NSString *> *> *records) {
    std::lock_guard<std::mutex> lock(gLock);
    gLoaded.store(true, std::memory_order_release);
    gRecords = [NSMutableDictionary dictionary];
    for (id item in records) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *who = NonEmpty(((NSDictionary *)item)[@"userName"]);
        if (!UserNameOK(who)) continue;
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        for (NSString *field in @[@"remark", @"groupNickname", @"nickname", @"alias"]) {
            NSString *text = NonEmpty(((NSDictionary *)item)[field]);
            if (text) row[field] = text;
        }
        if (row.count == 0) continue;
        row[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
        gRecords[who] = row;
    }
    TrimLocked();
    SaveLocked();
}

BOOL WCRContactNameNotifyEnabled(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kNotifyKey];
    return stored ? [stored boolValue] : NO;
}

void WCRContactNameSetNotifyEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kNotifyKey];
}

NSArray<NSString *> *WCRContactNameNotifyUserNames(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kNotifyIDsKey];
    if (![stored isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id item in (NSArray *)stored) {
        NSString *who = NonEmpty(item);
        if (!UserNameOK(who) || [names containsObject:who]) continue;
        [names addObject:who];
        if (names.count >= kMaxNotify) break;
    }
    return names;
}

void WCRContactNameSetNotifyUserNames(NSArray<NSString *> *userNames) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id item in userNames) {
        NSString *who = NonEmpty(item);
        if (!UserNameOK(who) || [names containsObject:who]) continue;
        [names addObject:who];
        if (names.count >= kMaxNotify) break;
    }
    [[NSUserDefaults standardUserDefaults] setObject:names forKey:kNotifyIDsKey];
}

void WCRContactNameResetForTesting(void) {
    std::lock_guard<std::mutex> lock(gLock);
    gTesting = YES;
    gRecords = [NSMutableDictionary dictionary];
    gLoaded.store(true, std::memory_order_release);
    gStyle.store(WCRContactNameStyleAuto, std::memory_order_relaxed);
    gStyleReady.store(true, std::memory_order_release);
}

void WCRContactNameRememberForTesting(NSString *userName,
                                     NSString *remark,
                                     NSString *groupNickname,
                                     NSString *nickname,
                                     NSString *alias) {
    NSString *who = NonEmpty(userName);
    if (!UserNameOK(who)) return;
    std::lock_guard<std::mutex> lock(gLock);
    gTesting = YES;
    MergeLocked(who, remark, groupNickname, nickname, alias);
}
