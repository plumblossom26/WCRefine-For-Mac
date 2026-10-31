#import "WCRContactPicker.h"

#import "WCRConfigStore.h"
#import "WCRContactName.h"
#import "WCROriginalID.h"

#import <AppKit/AppKit.h>

NSString *const WCRNotifyContactsDidChangeNotification = @"WCRefineMacNotifyContactsChanged";

static const NSUInteger kMaxNotify = 8;

static NSString *Trim(NSString *value) {
    return [value stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
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

static NSString *RowTitle(NSDictionary *row) {
    for (NSString *field in @[@"remark", @"groupNickname", @"nickname", @"alias"]) {
        NSString *text = Trim(row[field]);
        if (text.length) return text;
    }
    return row[@"userName"] ?: @"";
}

@interface WCRContactPickerController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTableView *table;
@property(nonatomic, strong) NSSearchField *searchField;
@property(nonatomic, strong) NSTextField *addField;
@property(nonatomic, strong) NSTextField *remarkField;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary<NSString *, id> *> *rows;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary<NSString *, id> *> *visible;
@property(nonatomic, assign) BOOL updatingRemark;
@end

@implementation WCRContactPickerController

- (void)present {
    if (!self.window) [self build];
    self.rows = WCRContactPickerBuildRows(WCROriginalIDRecentSessions(),
                                          WCRContactNameRecords(),
                                          WCRContactNameNotifyUserNames());
    self.searchField.stringValue = @"";
    [self applyFilter];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)build {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 560, 500)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"选择通知联系人";
    window.releasedWhenClosed = NO;
    window.level = NSFloatingWindowLevel;
    self.window = window;

    NSTextField *hint = [NSTextField labelWithString:
        @"名单来自最近会话和已保存联系人，名称来自见过的消息。也可以手填用户名；不读取微信数据库。最多 8 人，只发文字通知，不转发原消息。"];
    hint.frame = NSMakeRect(20, 452, 520, 36);
    hint.font = [NSFont systemFontOfSize:12];
    hint.maximumNumberOfLines = 2;

    self.searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(20, 416, 520, 28)];
    self.searchField.placeholderString = @"搜索名称或用户名";
    self.searchField.target = self;
    self.searchField.action = @selector(searchChanged:);

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 148, 520, 260)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSTableView *table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    NSTableColumn *check = [[NSTableColumn alloc] initWithIdentifier:@"notify"];
    check.title = @"通知";
    check.width = 48;
    NSButtonCell *checkCell = [[NSButtonCell alloc] init];
    checkCell.buttonType = NSButtonTypeSwitch;
    checkCell.title = @"";
    check.dataCell = checkCell;
    [table addTableColumn:check];
    NSTableColumn *name = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    name.title = @"名称";
    name.width = 220;
    [table addTableColumn:name];
    NSTableColumn *who = [[NSTableColumn alloc] initWithIdentifier:@"userName"];
    who.title = @"用户名";
    who.width = 220;
    [table addTableColumn:who];
    table.dataSource = self;
    table.delegate = self;
    table.headerView = [[NSTableHeaderView alloc] init];
    scroll.documentView = table;
    self.table = table;

    self.addField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 108, 360, 24)];
    self.addField.placeholderString = @"手填用户名，例如 wxid_xxx 或 123456@chatroom";
    NSButton *add = [NSButton buttonWithTitle:@"加入名单" target:self action:@selector(addUser:)];
    add.frame = NSMakeRect(392, 104, 148, 30);

    NSTextField *remarkLabel = [NSTextField labelWithString:@"备注"];
    remarkLabel.frame = NSMakeRect(20, 72, 40, 20);
    self.remarkField = [[NSTextField alloc] initWithFrame:NSMakeRect(64, 68, 476, 24)];
    self.remarkField.placeholderString = @"选中一行后可以改备注";
    self.remarkField.target = self;
    self.remarkField.action = @selector(remarkChanged:);
    self.remarkField.delegate = self;

    NSButton *done = [NSButton buttonWithTitle:@"完成" target:self action:@selector(commit:)];
    done.frame = NSMakeRect(452, 20, 88, 32);
    done.keyEquivalent = @"\r";

    for (NSView *view in @[hint, self.searchField, scroll, self.addField, add, remarkLabel, self.remarkField, done]) {
        [window.contentView addSubview:view];
    }
}

- (void)applyFilter {
    NSString *query = Trim(self.searchField.stringValue).lowercaseString;
    self.visible = [NSMutableArray array];
    for (NSMutableDictionary<NSString *, id> *row in self.rows) {
        if (!query.length) {
            [self.visible addObject:row];
            continue;
        }
        NSString *title = RowTitle(row).lowercaseString;
        NSString *who = [row[@"userName"] lowercaseString] ?: @"";
        if ([title containsString:query] || [who containsString:query]) [self.visible addObject:row];
    }
    [self.table reloadData];
    [self loadRemark];
}

- (void)searchChanged:(id)sender {
    (void)sender;
    [self applyFilter];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return self.visible.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)tableView;
    if (row < 0 || row >= (NSInteger)self.visible.count) return nil;
    NSDictionary *item = self.visible[row];
    if ([column.identifier isEqualToString:@"notify"]) return item[@"notify"];
    if ([column.identifier isEqualToString:@"name"]) return RowTitle(item);
    return item[@"userName"];
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)tableView;
    if (row < 0 || row >= (NSInteger)self.visible.count) return;
    if (![column.identifier isEqualToString:@"notify"]) return;
    self.visible[row][@"notify"] = @([object boolValue]);
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    [self loadRemark];
}

- (void)loadRemark {
    self.updatingRemark = YES;
    NSInteger row = self.table.selectedRow;
    BOOL has = row >= 0 && row < (NSInteger)self.visible.count;
    self.remarkField.enabled = has;
    self.remarkField.stringValue = has ? (self.visible[row][@"remark"] ?: @"") : @"";
    self.updatingRemark = NO;
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == self.remarkField) [self remarkChanged:nil];
}

- (void)remarkChanged:(id)sender {
    (void)sender;
    if (self.updatingRemark) return;
    NSInteger row = self.table.selectedRow;
    if (row < 0 || row >= (NSInteger)self.visible.count) return;
    NSString *remark = Trim(self.remarkField.stringValue);
    if (remark.length) self.visible[row][@"remark"] = remark;
    else [self.visible[row] removeObjectForKey:@"remark"];
    [self.table reloadData];
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
}

- (void)addUser:(id)sender {
    (void)sender;
    NSString *who = Trim(self.addField.stringValue);
    if (!UserNameOK(who)) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"用户名无效";
        alert.informativeText = @"需要 5 到 128 位的用户名，或数字 @chatroom。文件传输助手不能作为通知对象。";
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    for (NSMutableDictionary *row in self.rows) {
        if ([row[@"userName"] isEqualToString:who]) {
            row[@"notify"] = @YES;
            self.addField.stringValue = @"";
            [self applyFilter];
            return;
        }
    }
    [self.rows addObject:[@{@"userName": who, @"notify": @YES} mutableCopy]];
    self.addField.stringValue = @"";
    [self applyFilter];
}

- (void)commit:(id)sender {
    (void)sender;
    [self remarkChanged:nil];
    NSMutableArray<NSString *> *chosen = [NSMutableArray array];
    for (NSDictionary *row in self.rows) {
        if (![row[@"notify"] boolValue]) continue;
        NSString *who = row[@"userName"];
        if (!UserNameOK(who) || [chosen containsObject:who]) continue;
        [chosen addObject:who];
    }
    if (chosen.count > kMaxNotify) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"最多通知 8 个联系人";
        alert.informativeText = @"先去掉多出来的勾选，再点完成。";
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    NSMutableArray *records = [NSMutableArray array];
    for (NSDictionary *row in self.rows) {
        NSMutableDictionary *record = [NSMutableDictionary dictionary];
        record[@"userName"] = row[@"userName"];
        for (NSString *field in @[@"remark", @"groupNickname", @"nickname", @"alias"]) {
            if ([row[field] isKindOfClass:[NSString class]] && Trim(row[field]).length) {
                record[field] = Trim(row[field]);
            }
        }
        [records addObject:record];
    }
    WCRContactNameReplaceRecords(records);
    WCRContactNameSetNotifyUserNames(chosen);
    WCRConfigStoreBumpRevision();
    [[NSNotificationCenter defaultCenter]
        postNotificationName:WCRNotifyContactsDidChangeNotification object:nil];
    [self.window orderOut:nil];
}

@end

NSMutableArray<NSMutableDictionary<NSString *, id> *> *WCRContactPickerBuildRows(
    NSArray<NSDictionary<NSString *, id> *> *recentSessions,
    NSArray<NSDictionary<NSString *, id> *> *records,
    NSArray<NSString *> *notifyUserNames) {
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *known =
        [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *record in records) {
        id raw = record[@"userName"];
        if (![raw isKindOfClass:[NSString class]] || !UserNameOK((NSString *)raw)) continue;
        known[(NSString *)raw] = [record mutableCopy];
    }

    NSMutableArray<NSMutableDictionary<NSString *, id> *> *rows = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary<NSString *, id> *session in recentSessions) {
        id raw = session[@"value"];
        if (![raw isKindOfClass:[NSString class]]) continue;
        NSString *who = (NSString *)raw;
        if (!UserNameOK(who) || [seen containsObject:who]) continue;
        NSMutableDictionary<NSString *, id> *row = known[who] ?: [NSMutableDictionary dictionary];
        row[@"userName"] = who;
        [rows addObject:row];
        [seen addObject:who];
    }

    for (NSDictionary<NSString *, id> *record in records) {
        id raw = record[@"userName"];
        if (![raw isKindOfClass:[NSString class]]) continue;
        NSString *who = (NSString *)raw;
        if (!UserNameOK(who) || [seen containsObject:who]) continue;
        [rows addObject:known[who]];
        [seen addObject:who];
    }

    NSSet<NSString *> *chosen = [NSSet setWithArray:notifyUserNames];
    for (id item in notifyUserNames) {
        if (![item isKindOfClass:[NSString class]]) continue;
        NSString *who = (NSString *)item;
        if (!UserNameOK(who) || [seen containsObject:who]) continue;
        [rows addObject:[@{@"userName": who} mutableCopy]];
        [seen addObject:who];
    }
    for (NSMutableDictionary<NSString *, id> *row in rows) {
        row[@"notify"] = @([chosen containsObject:row[@"userName"]]);
    }
    return rows;
}

static WCRContactPickerController *gPicker;

void WCRContactPickerPresentForNotify(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gPicker) gPicker = [[WCRContactPickerController alloc] init];
        [gPicker present];
    });
}
