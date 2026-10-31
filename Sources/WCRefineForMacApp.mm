#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#import "WCRInstaller.h"
#import "WCRMachOInjector.h"
#import "WCRPatchProfiles.h"

static NSString *const kWCROriginalBundleIdentifier = @"com.tencent.xinWeChat";
static NSString *const kWCRGuideSeenDefaultsKey = @"WCRefineMacInstallerGuideSeen";

static NSString *WCRManagerLogPath(void) {
    NSString *logs = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:logs
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [logs stringByAppendingPathComponent:@"WCRefineForMac.log"];
}

static void WCRWriteManagerLog(NSString *message) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
        [formatter stringFromDate:[NSDate date]], message ?: @""];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = WCRManagerLogPath();
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [data writeToFile:path atomically:YES];
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @finally {
        [handle closeFile];
    }
}

typedef NS_ENUM(NSInteger, WCRActionRole) {
    WCRActionRoleSecondary = 0,
    WCRActionRolePrimary,
    WCRActionRoleDestructive,
};

// 非翻转的 NSClipView 会把短文档贴在底部。日志要顶对齐。
@interface WCRTopClipView : NSClipView
@end

@implementation WCRTopClipView
- (BOOL)isFlipped { return YES; }
@end

static NSTextField *WCRCaption(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    label.textColor = [NSColor labelColor];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [label setContentHuggingPriority:NSLayoutPriorityRequired
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [label setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

static NSTextField *WCRValueField(void) {
    NSTextField *label = [NSTextField labelWithString:@""];
    label.selectable = YES;
    label.font = [NSFont systemFontOfSize:13];
    label.textColor = [NSColor labelColor];
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    label.usesSingleLineMode = YES;
    label.maximumNumberOfLines = 1;
    label.cell.wraps = NO;
    label.cell.scrollable = YES;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [label setContentHuggingPriority:1
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

@interface WCRFlexibleSpaceView : NSView
@end

@implementation WCRFlexibleSpaceView
- (NSSize)intrinsicContentSize {
    // 只在横向上伸展。高度必须是 0，否则所在的按钮行没有固有高度，会把窗口多出来的空白吃掉。
    return NSMakeSize(NSViewNoIntrinsicMetric, 0);
}
@end

static NSView *WCRFlexibleSpace(void) {
    NSView *space = [[WCRFlexibleSpaceView alloc] initWithFrame:NSZeroRect];
    space.translatesAutoresizingMaskIntoConstraints = NO;
    [space setContentHuggingPriority:1
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [space setContentCompressionResistancePriority:1
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    [space setContentHuggingPriority:NSLayoutPriorityRequired
                       forOrientation:NSLayoutConstraintOrientationVertical];
    return space;
}

static NSStackView *WCRRow(NSArray<NSView *> *views, CGFloat spacing) {
    NSStackView *row = [NSStackView stackViewWithViews:views];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = spacing;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row setContentHuggingPriority:NSLayoutPriorityRequired
                    forOrientation:NSLayoutConstraintOrientationVertical];
    return row;
}

// 图标主体的绿色。主按钮不用系统强调色的亮蓝。
static NSColor *WCRPrimaryGreen(void) {
    return [NSColor colorWithSRGBRed:0.05 green:0.75 blue:0.40 alpha:1];
}

static void WCRApplyActionStyle(NSButton *button, NSString *symbol, WCRActionRole role) {
    button.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:button.title];
    button.imagePosition = NSImageLeading;
    button.imageScaling = NSImageScaleProportionallyDown;
    button.imageHugsTitle = YES;
    button.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    button.controlSize = NSControlSizeRegular;
    if (@available(macOS 26.0, *)) {
        button.bezelStyle = NSBezelStyleGlass;
        button.borderShape = NSControlBorderShapeCapsule;
        if (role == WCRActionRolePrimary) {
            button.tintProminence = NSTintProminencePrimary;
            button.bezelColor = WCRPrimaryGreen();
        } else if (role == WCRActionRoleDestructive) {
            button.hasDestructiveAction = YES;
            button.tintProminence = NSTintProminenceSecondary;
        } else {
            button.tintProminence = NSTintProminenceNone;
        }
    } else {
        button.bezelStyle = NSBezelStylePush;
        if (role == WCRActionRolePrimary) button.bezelColor = WCRPrimaryGreen();
        if (role == WCRActionRoleDestructive) button.hasDestructiveAction = YES;
    }
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setContentHuggingPriority:NSLayoutPriorityRequired
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [button setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
}

static NSButton *WCRActionButton(NSString *title,
                                 NSString *symbol,
                                 WCRActionRole role,
                                 id target,
                                 SEL action) {
    NSButton *button = [NSButton buttonWithTitle:title target:target action:action];
    WCRApplyActionStyle(button, symbol, role);
    return button;
}

static NSButton *WCRInlineButton(NSString *title, NSString *symbol, id target, SEL action) {
    NSButton *button = [NSButton buttonWithTitle:title target:target action:action];
    button.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
    button.imagePosition = NSImageLeading;
    button.imageHugsTitle = YES;
    button.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    button.bezelStyle = NSBezelStylePush;
    button.controlSize = NSControlSizeRegular;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setContentHuggingPriority:NSLayoutPriorityRequired
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [button setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    return button;
}

// 玻璃只做底板。内容是上面的普通子视图，避免 contentView 再排一次高度。
static NSView *WCRGlassPlate(NSView *content, CGFloat radius, BOOL expandsVertically) {
    NSView *plate = [[NSView alloc] initWithFrame:NSZeroRect];
    plate.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *glass = nil;
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *effect = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
        effect.cornerRadius = radius;
        effect.style = NSGlassEffectViewStyleRegular;
        glass = effect;
    } else {
        NSVisualEffectView *effect = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
        effect.material = NSVisualEffectMaterialContentBackground;
        effect.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        effect.state = NSVisualEffectStateFollowsWindowActiveState;
        effect.wantsLayer = YES;
        effect.layer.cornerRadius = radius;
        effect.layer.masksToBounds = YES;
        glass = effect;
    }
    glass.translatesAutoresizingMaskIntoConstraints = NO;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [plate addSubview:glass];
    [plate addSubview:content positioned:NSWindowAbove relativeTo:glass];
    // 可伸展的板子优先级要低于所有标题和按钮行，多出来的高度才落到日志上。
    NSLayoutPriority vertical = expandsVertically ? 1 : NSLayoutPriorityRequired;
    for (NSView *view in @[plate, glass, content]) {
        [view setContentHuggingPriority:vertical forOrientation:NSLayoutConstraintOrientationVertical];
        [view setContentCompressionResistancePriority:vertical forOrientation:NSLayoutConstraintOrientationVertical];
    }
    [NSLayoutConstraint activateConstraints:@[
        [glass.topAnchor constraintEqualToAnchor:plate.topAnchor],
        [glass.leadingAnchor constraintEqualToAnchor:plate.leadingAnchor],
        [glass.trailingAnchor constraintEqualToAnchor:plate.trailingAnchor],
        [glass.bottomAnchor constraintEqualToAnchor:plate.bottomAnchor],
        [content.topAnchor constraintEqualToAnchor:plate.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:plate.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:plate.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:plate.bottomAnchor],
    ]];
    return plate;
}

static void WCRHugVertically(NSView *view) {
    [view setContentHuggingPriority:NSLayoutPriorityRequired
                    forOrientation:NSLayoutConstraintOrientationVertical];
    [view setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                 forOrientation:NSLayoutConstraintOrientationVertical];
    // NSStackView 用自己的 huggingPriority 决定要不要长高，和 contentHugging 不是一回事。
    if ([view isKindOfClass:[NSStackView class]]) {
        [(NSStackView *)view setHuggingPriority:NSLayoutPriorityRequired
                                 forOrientation:NSLayoutConstraintOrientationVertical];
    }
}

static void WCRPinFullWidth(NSView *view, NSView *container) {
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    ]];
}

@interface WCRefineAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSView *guideView;
@property(nonatomic, strong) NSView *managerView;
@property(nonatomic, strong) NSButton *beginInstallButton;
@property(nonatomic, strong) NSTextField *sourceField;
@property(nonatomic, strong) NSTextField *statusField;
@property(nonatomic, strong) NSTextField *outputField;
@property(nonatomic, strong) NSTextField *progressField;
@property(nonatomic, strong) NSTextView *logView;
@property(nonatomic, strong) NSTextField *installedStateField;
@property(nonatomic, strong) NSTextField *multiStateField;
@property(nonatomic, strong) NSButton *installButton;
@property(nonatomic, strong) NSButton *launchButton;
@property(nonatomic, strong) NSButton *revealButton;
@property(nonatomic, strong) NSButton *createMultiButton;
@property(nonatomic, strong) NSButton *launchMultiButton;
@property(nonatomic, strong) NSButton *deleteMultiButton;
@property(nonatomic, strong) NSProgressIndicator *spinner;
@property(nonatomic, strong) NSURL *sourceAppURL;
@property(nonatomic, strong) NSURL *enhancedAppURL;
@property(nonatomic, assign) BOOL busy;
- (NSUInteger)multiInstanceNumberForAppURL:(NSURL *)appURL;
- (void)deleteMultiCopy:(id)sender;
- (void)openCommunityLink:(id)sender;
- (NSButton *)communityIconButtonWithImageName:(NSString *)imageName
                                           tag:(NSInteger)tag
                                       tooltip:(NSString *)tooltip;
- (NSArray<NSURL *> *)legacyBackupURLs;
- (void)cleanupLegacyBackups:(id)sender;
@end

@implementation WCRefineAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self buildMainMenu];
    [self buildWindow];

    NSURL *detected = [self detectWeChatApplication];
    if (detected) {
        self.sourceAppURL = detected;
    }
    self.enhancedAppURL = WCRDefaultEnhancedAppURL();
    self.sourceField.stringValue = self.sourceAppURL.path ?: @"未找到微信";
    self.outputField.stringValue = self.enhancedAppURL.path;
    WCRWriteManagerLog(@"manager launched");
    [self appendLog:@"WCRefine for Mac 已就绪。安装过程只生成副本，不修改原版微信。"];
    [self refreshInspection];
    [self refreshMultiInstanceState];
    if ([self shouldPresentGuideOnLaunch]) {
        [self showGuide:nil];
    } else {
        [self showManager:nil];
    }
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    (void)app;
    return YES;
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    [NSApp terminate:nil];
}

- (void)buildMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"WCRefine"];

    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"WCRefine" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"WCRefine"];
    NSMenuItem *about = [[NSMenuItem alloc] initWithTitle:@"关于 WCRefine for Mac"
                                                   action:@selector(orderFrontStandardAboutPanel:)
                                            keyEquivalent:@""];
    [appMenu addItem:about];
    NSMenuItem *guide = [[NSMenuItem alloc] initWithTitle:@"安装说明"
                                                   action:@selector(showGuide:)
                                            keyEquivalent:@""];
    guide.target = self;
    [appMenu addItem:guide];

    NSMenuItem *github = [[NSMenuItem alloc] initWithTitle:@"GitHub"
                                                    action:@selector(openCommunityLink:)
                                             keyEquivalent:@""];
    github.target = self;
    github.representedObject = [NSURL URLWithString:@"https://github.com/plumblossom26/WCRefine-For-Mac"];
    [appMenu addItem:github];

    NSMenuItem *telegram = [[NSMenuItem alloc] initWithTitle:@"Telegram 频道"
                                                      action:@selector(openCommunityLink:)
                                               keyEquivalent:@""];
    telegram.target = self;
    telegram.representedObject = [NSURL URLWithString:@"https://t.me/WCRefine"];
    [appMenu addItem:telegram];

    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *cleanup = [[NSMenuItem alloc] initWithTitle:@"清理旧版本备份…"
                                                     action:@selector(cleanupLegacyBackups:)
                                              keyEquivalent:@""];
    cleanup.target = self;
    [appMenu addItem:cleanup];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出 WCRefine"
                                                  action:@selector(terminate:)
                                           keyEquivalent:@"q"];
    [appMenu addItem:quit];
    appMenuItem.submenu = appMenu;
    [mainMenu addItem:appMenuItem];

    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:@"编辑" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"复制" action:@selector(copy:) keyEquivalent:@"c"]];
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"]];
    editMenuItem.submenu = editMenu;
    [mainMenu addItem:editMenuItem];
    [NSApp setMainMenu:mainMenu];
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 720, 640);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:NSWindowStyleMaskTitled |
                                                       NSWindowStyleMaskClosable |
                                                       NSWindowStyleMaskMiniaturizable
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.title = @"WCRefine for Mac";
    self.window.delegate = self;
    self.window.minSize = NSMakeSize(720, 640);
    self.window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    NSView *root = self.window.contentView;
    if (@available(macOS 26.0, *)) {
        // 标题栏不另画底，整窗用一块液态玻璃。内容贴在安全区，避开红绿灯。
        self.window.styleMask |= NSWindowStyleMaskFullSizeContentView;
        self.window.titlebarAppearsTransparent = YES;
        self.window.opaque = NO;
        self.window.backgroundColor = NSColor.clearColor;
        NSGlassEffectView *chrome = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
        chrome.translatesAutoresizingMaskIntoConstraints = NO;
        chrome.cornerRadius = 0;
        chrome.style = NSGlassEffectViewStyleRegular;
        [root addSubview:chrome];
        [NSLayoutConstraint activateConstraints:@[
            [chrome.topAnchor constraintEqualToAnchor:root.topAnchor],
            [chrome.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [chrome.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [chrome.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        ]];
    } else {
        self.window.backgroundColor = [NSColor windowBackgroundColor];
    }
    NSLayoutGuide *safe = self.window.contentLayoutGuide;
    self.managerView = [[NSView alloc] initWithFrame:NSZeroRect];
    self.managerView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:self.managerView];
    [NSLayoutConstraint activateConstraints:@[
        [self.managerView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.managerView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.managerView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.managerView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    ]];

    NSView *canvas = [[NSView alloc] initWithFrame:NSZeroRect];
    canvas.translatesAutoresizingMaskIntoConstraints = NO;
    [self.managerView addSubview:canvas];
    [NSLayoutConstraint activateConstraints:@[
        [canvas.leadingAnchor constraintEqualToAnchor:self.managerView.leadingAnchor],
        [canvas.trailingAnchor constraintEqualToAnchor:self.managerView.trailingAnchor],
        [canvas.topAnchor constraintEqualToAnchor:self.managerView.topAnchor],
        [canvas.bottomAnchor constraintEqualToAnchor:self.managerView.bottomAnchor],
    ]];

    NSImageView *appIcon = [NSImageView imageViewWithImage:[NSApp applicationIconImage]];
    appIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
    appIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [appIcon.widthAnchor constraintEqualToConstant:28],
        [appIcon.heightAnchor constraintEqualToConstant:28],
    ]];
    NSTextField *subtitle = WCRCaption(@"微信 macOS 增强版安装与管理");
    subtitle.font = [NSFont systemFontOfSize:13];
    subtitle.textColor = [NSColor secondaryLabelColor];
    [subtitle setContentHuggingPriority:NSLayoutPriorityDefaultLow
                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    [subtitle setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *guideButton = WCRActionButton(@"安装说明", @"questionmark.circle",
                                            WCRActionRoleSecondary, self, @selector(showGuide:));
    NSStackView *header = WCRRow(@[appIcon, subtitle, guideButton], 10);
    [canvas addSubview:header];
    [header.heightAnchor constraintEqualToAnchor:appIcon.heightAnchor].active = YES;

    NSTextField *sourceCaption = WCRCaption(@"微信");
    NSTextField *outputCaption = WCRCaption(@"输出");
    self.sourceField = WCRValueField();
    self.outputField = WCRValueField();
    NSButton *chooseButton = WCRInlineButton(@"选择…", @"folder", self, @selector(chooseSource:));
    NSStackView *sourceRow = WCRRow(@[sourceCaption, self.sourceField, chooseButton], 12);

    self.statusField = WCRValueField();
    self.statusField.lineBreakMode = NSLineBreakByTruncatingTail;
    self.statusField.stringValue = @"正在检查微信…";
    self.statusField.textColor = [NSColor secondaryLabelColor];
    self.statusField.font = [NSFont systemFontOfSize:12];

    NSBox *separator = [[NSBox alloc] initWithFrame:NSZeroRect];
    separator.boxType = NSBoxSeparator;
    separator.translatesAutoresizingMaskIntoConstraints = NO;

    self.installedStateField = WCRValueField();
    self.installedStateField.lineBreakMode = NSLineBreakByTruncatingTail;
    self.installedStateField.alignment = NSTextAlignmentRight;
    self.installedStateField.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    [self.installedStateField setContentHuggingPriority:NSLayoutPriorityRequired
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *outputRow = WCRRow(@[outputCaption, self.outputField, self.installedStateField], 12);

    NSStackView *sourceColumn = [NSStackView stackViewWithViews:@[sourceRow, self.statusField, separator, outputRow]];
    sourceColumn.orientation = NSUserInterfaceLayoutOrientationVertical;
    sourceColumn.alignment = NSLayoutAttributeLeading;
    sourceColumn.spacing = 10;
    sourceColumn.translatesAutoresizingMaskIntoConstraints = NO;
    WCRHugVertically(sourceColumn);
    NSView *sourceContent = [[NSView alloc] initWithFrame:NSZeroRect];
    [sourceContent addSubview:sourceColumn];
    NSView *sourcePlate = WCRGlassPlate(sourceContent, 20, NO);
    [canvas addSubview:sourcePlate];

    self.installButton = WCRActionButton(@"生成增强版", @"arrow.down.circle.fill",
                                         WCRActionRolePrimary, self, @selector(installEnhancedCopy:));
    self.installButton.keyEquivalent = @"\r";
    self.launchButton = WCRActionButton(@"启动", @"play.fill",
                                       WCRActionRoleSecondary, self, @selector(launchEnhancedCopy:));
    self.revealButton = WCRActionButton(@"Finder", @"folder",
                                       WCRActionRoleSecondary, self, @selector(revealEnhancedCopy:));
    self.revealButton.toolTip = @"在 Finder 中显示增强版微信";

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.displayedWhenStopped = NO;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.hidden = YES;
    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.widthAnchor constraintEqualToConstant:16],
        [self.spinner.heightAnchor constraintEqualToConstant:16],
    ]];
    self.progressField = WCRValueField();
    self.progressField.lineBreakMode = NSLineBreakByTruncatingTail;
    self.progressField.font = [NSFont systemFontOfSize:12];
    self.progressField.textColor = [NSColor secondaryLabelColor];
    self.progressField.selectable = NO;
    [self.progressField setContentHuggingPriority:NSLayoutPriorityDefaultLow
                           forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.progressField.widthAnchor constraintLessThanOrEqualToConstant:180].active = YES;
    NSStackView *progressRow = WCRRow(@[self.spinner, self.progressField], 6);
    progressRow.detachesHiddenViews = YES;

    // 操作按钮放在窗口玻璃上，不放进信息板，避免两层材质叠在一起。
    NSStackView *actionRow = WCRRow(@[
        self.installButton, self.launchButton, self.revealButton, WCRFlexibleSpace(), progressRow
    ], 8);
    // 横向栈没有有效的固有高度。不锁到按钮上时，窗口多出来的空白会落在这一行里。
    [actionRow.heightAnchor constraintEqualToAnchor:self.installButton.heightAnchor].active = YES;
    [canvas addSubview:actionRow];

    NSTextField *multiCaption = WCRCaption(@"多开副本");
    self.multiStateField = WCRValueField();
    self.multiStateField.lineBreakMode = NSLineBreakByTruncatingTail;
    self.multiStateField.textColor = [NSColor secondaryLabelColor];
    [self.multiStateField setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.createMultiButton = WCRActionButton(@"创建副本", @"plus",
                                            WCRActionRoleSecondary, self, @selector(createMultiCopy:));
    self.createMultiButton.toolTip = @"创建独立数据目录的多开副本";
    self.launchMultiButton = WCRActionButton(@"启动副本", @"play.fill",
                                            WCRActionRoleSecondary, self, @selector(launchMultiCopy:));
    self.launchMultiButton.toolTip = @"启动全部多开副本";
    self.deleteMultiButton = WCRActionButton(@"删除副本", @"trash",
                                            WCRActionRoleDestructive, self, @selector(deleteMultiCopy:));
    self.deleteMultiButton.toolTip = @"将多开副本移到废纸篓";
    NSStackView *multiTitle = WCRRow(@[multiCaption, self.multiStateField, WCRFlexibleSpace()], 8);
    NSStackView *multiActions = WCRRow(@[
        self.createMultiButton, self.launchMultiButton, self.deleteMultiButton, WCRFlexibleSpace()
    ], 8);
    [multiTitle.heightAnchor constraintEqualToAnchor:multiCaption.heightAnchor].active = YES;
    [multiActions.heightAnchor constraintEqualToAnchor:self.createMultiButton.heightAnchor].active = YES;
    NSView *multiBlock = [[NSView alloc] initWithFrame:NSZeroRect];
    multiBlock.translatesAutoresizingMaskIntoConstraints = NO;
    [multiBlock addSubview:multiTitle];
    [multiBlock addSubview:multiActions];
    [canvas addSubview:multiBlock];

    NSTextField *logCaption = WCRCaption(@"日志");
    NSTextField *logHint = [NSTextField labelWithString:@"本地运行记录"];
    logHint.font = [NSFont systemFontOfSize:12];
    logHint.textColor = [NSColor tertiaryLabelColor];
    logHint.translatesAutoresizingMaskIntoConstraints = NO;
    // 标题行不要用横向栈。空的占位视图没有固有高度，栈会被拉高，日志板就缩在底部。
    for (NSTextField *label in @[logCaption, logHint]) {
        [label setContentHuggingPriority:NSLayoutPriorityRequired
                          forOrientation:NSLayoutConstraintOrientationVertical];
        [label setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                       forOrientation:NSLayoutConstraintOrientationVertical];
    }
    [canvas addSubview:logCaption];
    [canvas addSubview:logHint];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = NO;
    scrollView.automaticallyAdjustsContentInsets = NO;
    scrollView.contentInsets = NSEdgeInsetsZero;
    WCRTopClipView *clipView = [[WCRTopClipView alloc] initWithFrame:NSZeroRect];
    clipView.drawsBackground = NO;
    scrollView.contentView = clipView;
    self.logView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 640, 160)];
    self.logView.editable = NO;
    self.logView.selectable = YES;
    self.logView.drawsBackground = NO;
    self.logView.textColor = [NSColor labelColor];
    self.logView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.logView.textContainerInset = NSMakeSize(12, 10);
    self.logView.minSize = NSMakeSize(0, 0);
    self.logView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.logView.verticallyResizable = YES;
    self.logView.horizontallyResizable = NO;
    self.logView.autoresizingMask = NSViewWidthSizable;
    self.logView.textContainer.widthTracksTextView = YES;
    scrollView.documentView = self.logView;
    NSView *logContent = [[NSView alloc] initWithFrame:NSZeroRect];
    [logContent addSubview:scrollView];
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:logContent.topAnchor constant:4],
        [scrollView.leadingAnchor constraintEqualToAnchor:logContent.leadingAnchor constant:4],
        [scrollView.trailingAnchor constraintEqualToAnchor:logContent.trailingAnchor constant:-4],
        [scrollView.bottomAnchor constraintEqualToAnchor:logContent.bottomAnchor constant:-4],
    ]];
    NSView *logPlate = WCRGlassPlate(logContent, 20, YES);
    [logPlate setContentHuggingPriority:NSLayoutPriorityFittingSizeCompression
                        forOrientation:NSLayoutConstraintOrientationVertical];
    [logPlate setContentCompressionResistancePriority:NSLayoutPriorityFittingSizeCompression
                                     forOrientation:NSLayoutConstraintOrientationVertical];
    [scrollView setContentHuggingPriority:NSLayoutPriorityFittingSizeCompression
                          forOrientation:NSLayoutConstraintOrientationVertical];
    [scrollView setContentCompressionResistancePriority:NSLayoutPriorityFittingSizeCompression
                                       forOrientation:NSLayoutConstraintOrientationVertical];
    [canvas addSubview:logPlate];

    NSView *column = [[NSView alloc] initWithFrame:NSZeroRect];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [column addSubview:header];
    [column addSubview:sourcePlate];
    [column addSubview:actionRow];
    [column addSubview:multiBlock];
    [canvas addSubview:column];

    [NSLayoutConstraint activateConstraints:@[
        [outputCaption.widthAnchor constraintEqualToAnchor:sourceCaption.widthAnchor],

        [column.topAnchor constraintEqualToAnchor:canvas.topAnchor constant:16],
        [column.leadingAnchor constraintEqualToAnchor:canvas.leadingAnchor constant:20],
        [column.trailingAnchor constraintEqualToAnchor:canvas.trailingAnchor constant:-20],
        [column.bottomAnchor constraintEqualToAnchor:multiBlock.bottomAnchor],

        [header.topAnchor constraintEqualToAnchor:column.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],

        [sourcePlate.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:14],
        [sourcePlate.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
        [sourcePlate.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],

        [actionRow.topAnchor constraintEqualToAnchor:sourcePlate.bottomAnchor constant:12],
        [actionRow.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
        [actionRow.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],

        [multiBlock.topAnchor constraintEqualToAnchor:actionRow.bottomAnchor constant:16],
        [multiBlock.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
        [multiBlock.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],
        [multiTitle.topAnchor constraintEqualToAnchor:multiBlock.topAnchor],
        [multiTitle.leadingAnchor constraintEqualToAnchor:multiBlock.leadingAnchor],
        [multiTitle.trailingAnchor constraintEqualToAnchor:multiBlock.trailingAnchor],
        [multiActions.topAnchor constraintEqualToAnchor:multiTitle.bottomAnchor constant:8],
        [multiActions.leadingAnchor constraintEqualToAnchor:multiBlock.leadingAnchor],
        [multiActions.trailingAnchor constraintEqualToAnchor:multiBlock.trailingAnchor],
        [multiActions.bottomAnchor constraintEqualToAnchor:multiBlock.bottomAnchor],

        [sourceColumn.topAnchor constraintEqualToAnchor:sourceContent.topAnchor constant:14],
        [sourceColumn.leadingAnchor constraintEqualToAnchor:sourceContent.leadingAnchor constant:16],
        [sourceColumn.trailingAnchor constraintEqualToAnchor:sourceContent.trailingAnchor constant:-16],
        [sourceColumn.bottomAnchor constraintEqualToAnchor:sourceContent.bottomAnchor constant:-14],
        [separator.heightAnchor constraintEqualToConstant:1],

        [logCaption.topAnchor constraintEqualToAnchor:column.bottomAnchor constant:16],
        [logCaption.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
        [logHint.centerYAnchor constraintEqualToAnchor:logCaption.centerYAnchor],
        [logHint.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],
        [logHint.leadingAnchor constraintGreaterThanOrEqualToAnchor:logCaption.trailingAnchor constant:12],

        [logPlate.topAnchor constraintEqualToAnchor:logCaption.bottomAnchor constant:8],
        [logPlate.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
        [logPlate.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],
        [logPlate.bottomAnchor constraintEqualToAnchor:canvas.bottomAnchor constant:-16],
        [logPlate.heightAnchor constraintGreaterThanOrEqualToConstant:160],
    ]];
    WCRPinFullWidth(sourceRow, sourceColumn);
    WCRPinFullWidth(self.statusField, sourceColumn);
    WCRPinFullWidth(separator, sourceColumn);
    WCRPinFullWidth(outputRow, sourceColumn);

    self.launchButton.enabled = NO;
    self.revealButton.enabled = NO;
    self.createMultiButton.enabled = NO;
    self.launchMultiButton.enabled = NO;
    self.deleteMultiButton.enabled = NO;
    [self refreshOutputState];
    [self buildGuideView];
}

- (NSTextField *)guideText:(NSString *)text
                     size:(CGFloat)size
                   weight:(NSFontWeight)weight
                    color:(NSColor *)color
                alignment:(NSTextAlignment)alignment {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.stringValue = text ?: @"";
    label.editable = NO;
    label.selectable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color ?: [NSColor labelColor];
    label.alignment = alignment;
    label.usesSingleLineMode = NO;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.maximumNumberOfLines = 0;
    label.cell.wraps = YES;
    label.cell.scrollable = NO;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (NSView *)guideFeatureWithSymbol:(NSString *)symbol
                             title:(NSString *)title
                            detail:(NSString *)detail {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
    NSImageSymbolConfiguration *configuration =
        [NSImageSymbolConfiguration configurationWithPointSize:20 weight:NSFontWeightSemibold];
    image = [image imageWithSymbolConfiguration:configuration];

    NSImageView *icon = [NSImageView imageViewWithImage:image];
    icon.contentTintColor = [NSColor controlAccentColor];
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon setContentHuggingPriority:NSLayoutPriorityRequired
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:28],
        [icon.heightAnchor constraintEqualToConstant:28],
    ]];

    NSTextField *titleField = [self guideText:title
                                          size:13
                                        weight:NSFontWeightSemibold
                                         color:[NSColor labelColor]
                                     alignment:NSTextAlignmentLeft];
    NSTextField *detailField = [self guideText:detail
                                           size:12
                                         weight:NSFontWeightRegular
                                          color:[NSColor secondaryLabelColor]
                                      alignment:NSTextAlignmentLeft];
    [detailField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                           forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *text = [NSStackView stackViewWithViews:@[titleField, detailField]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 2;
    text.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *row = [NSStackView stackViewWithViews:@[icon, text]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 12;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.widthAnchor constraintEqualToConstant:440].active = YES;
    return row;
}

- (void)buildGuideView {
    NSView *root = self.window.contentView;
    NSLayoutGuide *safe = self.window.contentLayoutGuide;
    self.guideView = [[NSView alloc] initWithFrame:NSZeroRect];
    self.guideView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:self.guideView];
    [NSLayoutConstraint activateConstraints:@[
        [self.guideView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.guideView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.guideView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.guideView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    ]];
    NSView *guide = self.guideView;

    NSImage *appIcon = [NSApp applicationIconImage] ?: [NSImage imageNamed:NSImageNameApplicationIcon];
    NSImageView *iconView = [NSImageView imageViewWithImage:appIcon];
    iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:88],
        [iconView.heightAnchor constraintEqualToConstant:88],
    ]];

    NSTextField *titleField = [self guideText:@"欢迎使用 WCRefine"
                                          size:26
                                        weight:NSFontWeightBold
                                         color:[NSColor labelColor]
                                     alignment:NSTextAlignmentCenter];
    NSTextField *subtitleField = [self guideText:@"基于微信 macOS 4.1.15.55（270135）制作。\n复制一份微信并载入插件，原来的微信不会被修改。"
                                             size:13
                                           weight:NSFontWeightRegular
                                            color:[NSColor secondaryLabelColor]
                                        alignment:NSTextAlignmentCenter];
    [subtitleField.widthAnchor constraintEqualToConstant:460].active = YES;

    NSView *copyRow = [self guideFeatureWithSymbol:@"square.on.square"
                                             title:@"只生成副本"
                                            detail:@"不改「应用程序」里的原版。再次生成会原地替换，不再堆积备份。"];
    NSView *versionRow = [self guideFeatureWithSymbol:@"checkmark.seal"
                                                title:@"已验证版本优先"
                                               detail:@"有已验证构建时自动选用。其它版本也能安装，未登记的功能保持关闭。"];
    NSView *launchRow = [self guideFeatureWithSymbol:@"arrow.right.circle"
                                               title:@"退出后再打开"
                                              detail:@"先完全退出原版，再启动增强版。被系统拦住时，右键选择「打开」。"];

    NSStackView *features = [NSStackView stackViewWithViews:@[copyRow, versionRow, launchRow]];
    features.orientation = NSUserInterfaceLayoutOrientationVertical;
    features.alignment = NSLayoutAttributeLeading;
    features.spacing = 18;
    features.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *githubLink = [self communityIconButtonWithImageName:@"GitHubTemplate"
                                                              tag:1
                                                          tooltip:@"GitHub：github.com/plumblossom26/WCRefine-For-Mac"];
    NSButton *telegramLink = [self communityIconButtonWithImageName:@"TelegramTemplate"
                                                                tag:2
                                                            tooltip:@"Telegram 频道：t.me/WCRefine"];
    NSStackView *links = [NSStackView stackViewWithViews:@[githubLink, telegramLink]];
    links.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    links.alignment = NSLayoutAttributeCenterY;
    links.spacing = 10;
    links.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *hero = [NSStackView stackViewWithViews:@[iconView, titleField, subtitleField, features]];
    hero.orientation = NSUserInterfaceLayoutOrientationVertical;
    hero.alignment = NSLayoutAttributeCenterX;
    hero.spacing = 8;
    hero.translatesAutoresizingMaskIntoConstraints = NO;
    [hero setCustomSpacing:18 afterView:iconView];
    [hero setCustomSpacing:8 afterView:titleField];
    [hero setCustomSpacing:28 afterView:subtitleField];
    [hero setCustomSpacing:22 afterView:features];
    [guide addSubview:hero];
    [guide addSubview:links];

    NSBox *separator = [[NSBox alloc] initWithFrame:NSZeroRect];
    separator.boxType = NSBoxSeparator;
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    [guide addSubview:separator];

    self.beginInstallButton = [NSButton buttonWithTitle:@"继续" target:self action:@selector(beginInstallFromGuide:)];
    WCRApplyActionStyle(self.beginInstallButton, @"arrow.right", WCRActionRolePrimary);
    [guide addSubview:self.beginInstallButton];

    [NSLayoutConstraint activateConstraints:@[
        [hero.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],
        [hero.centerYAnchor constraintEqualToAnchor:guide.centerYAnchor constant:-30],
        [hero.topAnchor constraintGreaterThanOrEqualToAnchor:guide.topAnchor constant:28],
        [hero.leadingAnchor constraintGreaterThanOrEqualToAnchor:guide.leadingAnchor constant:28],
        [hero.bottomAnchor constraintLessThanOrEqualToAnchor:separator.topAnchor constant:-20],

        [separator.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:self.beginInstallButton.topAnchor constant:-14],

        [self.beginInstallButton.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],
        [self.beginInstallButton.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-16],
        [self.beginInstallButton.widthAnchor constraintGreaterThanOrEqualToConstant:88],

        [links.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [links.centerYAnchor constraintEqualToAnchor:self.beginInstallButton.centerYAnchor],
        [links.trailingAnchor constraintLessThanOrEqualToAnchor:self.beginInstallButton.leadingAnchor constant:-12],
    ]];

    self.guideView.hidden = YES;
    self.managerView.hidden = NO;
}

- (BOOL)enhancedCopyExists {
    return self.enhancedAppURL &&
        [[NSFileManager defaultManager] fileExistsAtPath:self.enhancedAppURL.path];
}

- (BOOL)shouldPresentGuideOnLaunch {
    if (![self enhancedCopyExists]) return YES;
    return ![[NSUserDefaults standardUserDefaults] boolForKey:kWCRGuideSeenDefaultsKey];
}

- (void)showGuide:(id)sender {
    (void)sender;
    self.beginInstallButton.title = @"继续";
    self.guideView.hidden = NO;
    self.managerView.hidden = YES;
    self.beginInstallButton.keyEquivalent = @"\r";
    self.installButton.keyEquivalent = @"";
    if (!self.busy) self.window.title = @"WCRefine for Mac";
}

- (void)showManager:(id)sender {
    (void)sender;
    self.guideView.hidden = YES;
    self.managerView.hidden = NO;
    self.beginInstallButton.keyEquivalent = @"";
    self.installButton.keyEquivalent = @"\r";
    if (!self.busy) self.window.title = @"WCRefine for Mac";
}

- (void)beginInstallFromGuide:(id)sender {
    (void)sender;
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kWCRGuideSeenDefaultsKey];
    [self showManager:nil];
}

- (NSURL *)detectWeChatApplication {
    NSArray<NSString *> *candidates = @[
        @"/Applications/WeChat.app",
        @"/Applications/微信.app",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/WeChat.app"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/微信.app"],
    ];
    NSURL *firstValid = nil;
    NSURL *bestSupported = nil;
    unsigned long long bestBuild = 0;
    for (NSString *path in candidates) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
            [path stringByAppendingPathComponent:@"Contents/Info.plist"]];
        if (![info[@"CFBundleIdentifier"] isEqualToString:kWCROriginalBundleIdentifier]) {
            continue;
        }
        WCRAppInspection inspection{};
        if (!WCRInspectWeChatApp(path, &inspection, nil)) continue;
        NSURL *candidate = [NSURL fileURLWithPath:path isDirectory:YES];
        if (!firstValid) firstValid = candidate;
        if (!inspection.supported) continue;
        unsigned long long build = inspection.buildVersion.longLongValue;
        if (!bestSupported || build > bestBuild) {
            bestSupported = candidate;
            bestBuild = build;
        }
    }
    return bestSupported ?: firstValid;
}

- (void)chooseSource:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"选择微信应用";
    panel.prompt = @"选择";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.treatsFilePackagesAsDirectories = NO;
    panel.directoryURL = [NSURL fileURLWithPath:@"/Applications" isDirectory:YES];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        self.sourceAppURL = panel.URL;
        self.sourceField.stringValue = panel.URL.path;
        [self refreshInspection];
    }];
}

- (void)refreshInspection {
    if (!self.sourceAppURL) {
        self.statusField.textColor = [NSColor systemRedColor];
        self.statusField.stringValue = @"未找到微信。请选择包含 com.tencent.xinWeChat 的应用。";
        self.installButton.enabled = NO;
        return;
    }

    WCRAppInspection inspection{};
    NSError *error = nil;
    if (!WCRInspectWeChatApp(self.sourceAppURL.path, &inspection, &error)) {
        self.statusField.textColor = [NSColor systemRedColor];
        NSMutableString *message = [NSMutableString stringWithFormat:@"当前微信不可用：%@",
            error.localizedDescription ?: @"未知错误"];
        NSArray<NSString *> *supported = WCRSupportedBuildDescriptions();
        if (supported.count) {
            [message appendString:@"\n支持版本："];
            [message appendString:[supported componentsJoinedByString:@"、"]];
        }
        self.statusField.stringValue = message;
        self.installButton.enabled = NO;
        [self refreshOutputState];
        return;
    }

    self.installButton.enabled = !self.busy;
    if (!inspection.supported) {
        self.statusField.textColor = [NSColor systemOrangeColor];
        self.statusField.stringValue = [NSString stringWithFormat:
            @"%@。仍可生成增强版，未登记的功能保持关闭。",
            inspection.failureReason.length ? inspection.failureReason : @"当前构建未完全匹配"];
        [self refreshOutputState];
        return;
    }

    self.statusField.textColor = [NSColor systemGreenColor];
    self.statusField.stringValue = [NSString stringWithFormat:
        @"已识别微信 %@（%@），补丁点%@。",
        inspection.shortVersion ?: @"?",
        inspection.buildVersion ?: @"?",
        inspection.alreadyPatched ? @"已处于补丁状态" : @"校验通过"];
    [self refreshOutputState];
}

- (void)refreshOutputState {
    BOOL installed = self.enhancedAppURL &&
        [[NSFileManager defaultManager] fileExistsAtPath:self.enhancedAppURL.path];
    self.installedStateField.stringValue = installed ? @"已生成" : @"未生成";
    self.installedStateField.textColor = installed ? [NSColor systemGreenColor] : [NSColor secondaryLabelColor];
    self.launchButton.enabled = installed && !self.busy;
    self.revealButton.enabled = installed && !self.busy;
    [self refreshMultiInstanceState];
}

#pragma mark - 多开副本

- (NSArray<NSURL *> *)existingMultiInstanceAppURLs {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSUInteger number = 2; number <= 99; ++number) {
        NSURL *url = WCRDefaultMultiInstanceAppURL(number);
        if ([[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
            [urls addObject:url];
        }
    }
    return urls;
}

- (void)refreshMultiInstanceState {
    NSMutableArray<NSString *> *numbers = [NSMutableArray array];
    BOOL anyRunning = NO;
    for (NSUInteger number = 2; number <= 99; ++number) {
        NSURL *url = WCRDefaultMultiInstanceAppURL(number);
        if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) continue;
        [numbers addObject:[NSString stringWithFormat:@"%lu", (unsigned long)number]];
        if ([NSRunningApplication
                runningApplicationsWithBundleIdentifier:WCRMultiInstanceBundleIdentifier(number)].count > 0) {
            anyRunning = YES;
        }
    }
    if (numbers.count == 0) {
        self.multiStateField.stringValue = @"未生成";
        self.multiStateField.textColor = [NSColor secondaryLabelColor];
    } else {
        NSString *summary = [NSString stringWithFormat:@"%lu 个（%@）",
            (unsigned long)numbers.count, [numbers componentsJoinedByString:@"、"]];
        if (anyRunning) summary = [summary stringByAppendingString:@" · 运行中"];
        self.multiStateField.stringValue = summary;
        self.multiStateField.textColor = [NSColor systemGreenColor];
    }
    BOOL hasCopies = numbers.count > 0;
    self.launchMultiButton.enabled = hasCopies && !self.busy;
    self.deleteMultiButton.enabled = hasCopies && !self.busy;
    self.createMultiButton.enabled = !self.busy && self.sourceAppURL != nil &&
        WCRNextMultiInstanceNumber() != 0;
}

- (NSUInteger)multiInstanceNumberForAppURL:(NSURL *)appURL {
    for (NSUInteger number = 2; number <= 99; ++number) {
        if ([WCRDefaultMultiInstanceAppURL(number).path isEqualToString:appURL.path]) return number;
    }
    return 0;
}

- (void)deleteMultiCopy:(id)sender {
    (void)sender;
    if (self.busy) return;
    NSArray<NSURL *> *copies = [self existingMultiInstanceAppURLs];
    if (copies.count == 0) return;

    NSURL *selected = copies.lastObject;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"删除多开副本？";
    alert.informativeText = @"副本会移到废纸篓；独立聊天数据容器不会自动删除。";
    NSPopUpButton *picker = nil;
    if (copies.count > 1) {
        picker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 320, 26) pullsDown:NO];
        for (NSURL *url in copies) {
            [picker addItemWithTitle:url.lastPathComponent];
            picker.lastItem.representedObject = url;
        }
        alert.accessoryView = picker;
    } else {
        alert.informativeText = [NSString stringWithFormat:
            @"%@ 会移到废纸篓；独立聊天数据容器不会自动删除。", selected.lastPathComponent];
    }
    [alert addButtonWithTitle:@"移到废纸篓"];
    [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    if (picker && picker.selectedItem.representedObject) {
        selected = picker.selectedItem.representedObject;
    }

    NSUInteger number = [self multiInstanceNumberForAppURL:selected];
    if (number != 0 && [NSRunningApplication
            runningApplicationsWithBundleIdentifier:WCRMultiInstanceBundleIdentifier(number)].count > 0) {
        NSAlert *runningAlert = [[NSAlert alloc] init];
        runningAlert.alertStyle = NSAlertStyleWarning;
        runningAlert.messageText = @"多开副本正在运行";
        runningAlert.informativeText = [NSString stringWithFormat:
            @"请先完全退出 %@，再删除副本。", selected.lastPathComponent];
        [runningAlert runModal];
        return;
    }

    NSError *error = nil;
    NSURL *trashedURL = nil;
    if (![[NSFileManager defaultManager] trashItemAtURL:selected
                                      resultingItemURL:&trashedURL
                                                 error:&error]) {
        NSAlert *failure = [[NSAlert alloc] init];
        failure.alertStyle = NSAlertStyleCritical;
        failure.messageText = @"无法删除多开副本";
        failure.informativeText = error.localizedDescription ?: @"未知错误";
        [failure runModal];
        return;
    }

    self.statusField.textColor = [NSColor systemGreenColor];
    self.statusField.stringValue = @"多开副本已移到废纸篓。";
    [self appendLog:[NSString stringWithFormat:@"已移到废纸篓: %@",
        trashedURL.path ?: selected.path]];
    WCRWriteManagerLog([NSString stringWithFormat:@"multi copy trashed output=%@",
        trashedURL.path ?: selected.path]);
    [self refreshMultiInstanceState];
}

- (NSButton *)communityIconButtonWithImageName:(NSString *)imageName
                                           tag:(NSInteger)tag
                                       tooltip:(NSString *)tooltip {
    NSImage *image = [NSImage imageNamed:imageName];
    [image setTemplate:YES];
    NSButton *button = [NSButton buttonWithImage:image
                                           target:self
                                           action:@selector(openCommunityLink:)];
    button.bezelStyle = NSBezelStyleInline;
    button.bordered = NO;
    button.imageScaling = NSImageScaleProportionallyUpOrDown;
    button.contentTintColor = [NSColor secondaryLabelColor];
    button.tag = tag;
    button.toolTip = tooltip;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:28],
        [button.heightAnchor constraintEqualToConstant:28],
    ]];
    return button;
}

- (void)openCommunityLink:(id)sender {
    NSURL *url = nil;
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        url = [(NSMenuItem *)sender representedObject];
    } else if ([sender isKindOfClass:[NSButton class]]) {
        NSString *address = ((NSButton *)sender).tag == 1
            ? @"https://github.com/plumblossom26/WCRefine-For-Mac"
            : @"https://t.me/WCRefine";
        url = [NSURL URLWithString:address];
    }
    if ([url isKindOfClass:[NSURL class]]) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

- (NSArray<NSURL *> *)legacyBackupURLs {
    NSURL *directory = self.enhancedAppURL.URLByDeletingLastPathComponent;
    if (!directory) return @[];
    NSError *error = nil;
    NSArray<NSURL *> *items = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:directory
      includingPropertiesForKeys:nil
                         options:0
                           error:&error];
    if (!items) return @[];
    NSMutableArray<NSURL *> *backups = [NSMutableArray array];
    for (NSURL *url in items) {
        NSString *name = url.lastPathComponent;
        if ([name containsString:@".app.previous-"] || [name containsString:@".app.old-"]) {
            [backups addObject:url];
        }
    }
    return backups;
}

- (void)cleanupLegacyBackups:(id)sender {
    (void)sender;
    NSArray<NSURL *> *backups = [self legacyBackupURLs];
    if (backups.count == 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = @"没有旧版本备份";
        alert.informativeText = @"覆盖安装不会再生成新的备份副本。";
        [alert runModal];
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = [NSString stringWithFormat:@"清理 %lu 个旧版本备份？",
        (unsigned long)backups.count];
    alert.informativeText = @"这些是早期覆盖安装留下的完整 App 副本，不是多开副本。清理后会移到废纸篓。";
    [alert addButtonWithTitle:@"移到废纸篓"];
    [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSUInteger removed = 0;
    NSError *firstError = nil;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSURL *url in backups) {
        NSError *error = nil;
        if ([fileManager trashItemAtURL:url resultingItemURL:nil error:&error]) {
            ++removed;
        } else if (!firstError) {
            firstError = error;
        }
    }

    self.statusField.textColor = removed ? [NSColor systemGreenColor] : [NSColor systemRedColor];
    self.statusField.stringValue = [NSString stringWithFormat:@"已清理 %lu 个旧版本备份。",
        (unsigned long)removed];
    [self appendLog:[NSString stringWithFormat:@"旧版本备份已移到废纸篓: %lu 个",
        (unsigned long)removed]];
    WCRWriteManagerLog([NSString stringWithFormat:@"legacy backups trashed count=%lu",
        (unsigned long)removed]);
    if (firstError) {
        NSAlert *failure = [[NSAlert alloc] init];
        failure.alertStyle = NSAlertStyleWarning;
        failure.messageText = @"部分旧版本备份未清理";
        failure.informativeText = firstError.localizedDescription ?: @"未知错误";
        [failure runModal];
    }
}

- (void)createMultiCopy:(id)sender {
    (void)sender;
    if (self.busy || !self.sourceAppURL) return;
    NSUInteger number = WCRNextMultiInstanceNumber();
    if (number == 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"多开副本数量已达上限";
        [alert runModal];
        return;
    }
    NSURL *destination = WCRDefaultMultiInstanceAppURL(number);
    NSString *bundleIdentifier = WCRMultiInstanceBundleIdentifier(number);
    NSString *displayName = [NSString stringWithFormat:@"WCRefine 微信 多开%lu",
                                                            (unsigned long)number];
    NSString *dylibPath = [[NSBundle mainBundle] pathForResource:@"WCRefineMac" ofType:@"dylib"];
    if (!dylibPath) {
        dylibPath = [[[NSBundle mainBundle] bundlePath]
            stringByAppendingPathComponent:@"Contents/Resources/WCRefineMac.dylib"];
    }

    [self appendLog:[NSString stringWithFormat:@"开始生成多开副本 %@（%@）。", destination.lastPathComponent, bundleIdentifier]];
    [self setBusy:YES progress:@"准备中…"];

    NSURL *source = self.sourceAppURL;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSError *error = nil;
        BOOL succeeded = WCRInstallEnhancedCopyWithOptions(source,
                                                           destination,
                                                           dylibPath,
                                                           bundleIdentifier,
                                                           displayName,
                                                           NO,
                                                           ^(NSString *message) {
            [self appendLog:message];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.progressField.stringValue = message;
            });
        },
                                                           &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setBusy:NO progress:succeeded ? @"完成" : @"失败"];
            [self refreshInspection];
            [self refreshOutputState];
            if (succeeded) {
                self.statusField.textColor = [NSColor systemGreenColor];
                self.statusField.stringValue = @"多开副本已生成，可同时运行。";
                WCRWriteManagerLog([NSString stringWithFormat:@"multi install succeeded output=%@ bundleID=%@",
                                                              destination.path, bundleIdentifier]);
                [self appendLog:[NSString stringWithFormat:
                    @"多开副本 %@ 已生成。拥有独立数据目录，可与原版微信/主副本同时运行；首次启动需扫码登录。", destination.lastPathComponent]];
            } else {
                self.statusField.textColor = [NSColor systemRedColor];
                self.statusField.stringValue = error.localizedDescription ?: @"生成失败";
                WCRWriteManagerLog([NSString stringWithFormat:@"multi install failed: %@",
                                                              error.localizedDescription ?: @"未知错误"]);
                [self appendLog:[NSString stringWithFormat:@"失败：%@",
                    error.localizedDescription ?: @"未知错误"]];
            }
        });
    });
}

- (void)launchMultiCopy:(id)sender {
    (void)sender;
    if (self.busy) return;

    // 多开副本拥有独立 bundle id / 沙盒容器，无需先退出原版微信。
    for (NSUInteger number = 2; number <= 99; ++number) {
        NSURL *url = WCRDefaultMultiInstanceAppURL(number);
        if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) continue;
        NSString *bundleIdentifier = WCRMultiInstanceBundleIdentifier(number);
        NSArray<NSRunningApplication *> *running =
            [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
        if (running.count > 0) {
            [running.firstObject activateWithOptions:NSApplicationActivateIgnoringOtherApps];
            continue;
        }
        NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
        [[NSWorkspace sharedWorkspace] openApplicationAtURL:url
                                              configuration:configuration
                                          completionHandler:^(NSRunningApplication *app, NSError *launchError) {
            (void)app;
            if (launchError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSAlert *alert = [[NSAlert alloc] init];
                    alert.alertStyle = NSAlertStyleCritical;
                    alert.messageText = @"无法启动多开副本";
                    alert.informativeText = launchError.localizedDescription;
                    [alert runModal];
                });
            } else {
                [self appendLog:[NSString stringWithFormat:@"已启动多开副本: %@",
                                                           url.lastPathComponent]];
            }
        }];
    }
}

- (void)appendLog:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
            [NSDateFormatter localizedStringFromDate:[NSDate date]
                                           dateStyle:NSDateFormatterNoStyle
                                           timeStyle:NSDateFormatterMediumStyle],
            message];
        [self.logView.textStorage appendAttributedString:
            [[NSAttributedString alloc] initWithString:line attributes:@{
                NSFontAttributeName: self.logView.font,
                NSForegroundColorAttributeName: [NSColor labelColor],
            }]];
        [self.logView scrollToEndOfDocument:nil];
    });
}

- (void)setBusy:(BOOL)busy progress:(NSString *)progress {
    self.busy = busy;
    self.window.title = busy ? @"WCRefine for Mac — 正在安装" : @"WCRefine for Mac";
    self.installButton.title = busy ? @"正在安装…" : @"生成增强版";
    self.installButton.enabled = !busy && self.sourceAppURL != nil;
    self.launchButton.enabled = !busy && self.enhancedAppURL != nil &&
        [[NSFileManager defaultManager] fileExistsAtPath:self.enhancedAppURL.path];
    self.revealButton.enabled = !busy && self.enhancedAppURL != nil &&
        [[NSFileManager defaultManager] fileExistsAtPath:self.enhancedAppURL.path];
    self.createMultiButton.enabled = !busy && self.sourceAppURL != nil &&
        WCRNextMultiInstanceNumber() != 0;
    BOOL hasMultiCopies = [self existingMultiInstanceAppURLs].count > 0;
    self.launchMultiButton.enabled = !busy && hasMultiCopies;
    self.deleteMultiButton.enabled = !busy && hasMultiCopies;
    self.progressField.stringValue = progress ?: @"";
    self.spinner.hidden = !busy;
    if (busy) {
        [self.spinner startAnimation:nil];
    } else {
        [self.spinner stopAnimation:nil];
    }
}

- (void)installEnhancedCopy:(id)sender {
    (void)sender;
    if (self.busy || !self.sourceAppURL) return;

    BOOL destinationExists = [[NSFileManager defaultManager]
        fileExistsAtPath:self.enhancedAppURL.path];
    if (destinationExists) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"增强版微信已存在";
        alert.informativeText = @"重新生成会原地替换当前增强版，不会新增备份副本。";
        [alert addButtonWithTitle:@"重新生成"];
        [alert addButtonWithTitle:@"取消"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }

    self.statusField.textColor = [NSColor secondaryLabelColor];
    self.statusField.stringValue = @"开始生成增强版微信…";
    WCRWriteManagerLog([NSString stringWithFormat:@"install started source=%@", self.sourceAppURL.path]);
    [self appendLog:@"开始生成增强版微信。"];
    [self setBusy:YES progress:@"准备中…"];

    NSURL *source = self.sourceAppURL;
    NSURL *destination = self.enhancedAppURL;
    NSString *dylibPath = [[NSBundle mainBundle] pathForResource:@"WCRefineMac" ofType:@"dylib"];
    if (!dylibPath) {
        dylibPath = [[[NSBundle mainBundle] bundlePath]
            stringByAppendingPathComponent:@"Contents/Resources/WCRefineMac.dylib"];
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSError *error = nil;
        BOOL succeeded = WCRInstallEnhancedCopy(source,
                                                 destination,
                                                 dylibPath,
                                                 YES,
                                                 ^(NSString *message) {
            [self appendLog:message];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.progressField.stringValue = message;
            });
        },
                                                 &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setBusy:NO progress:succeeded ? @"完成" : @"失败"];
            [self refreshInspection];
            [self refreshOutputState];
            if (succeeded) {
                self.statusField.textColor = [NSColor systemGreenColor];
                self.statusField.stringValue = @"增强版微信已生成并通过代码签名验证。";
                WCRWriteManagerLog([NSString stringWithFormat:@"install succeeded output=%@", self.enhancedAppURL.path]);
                [self appendLog:@"生成完成。请先完全退出原版微信，再启动增强版。"];

                NSAlert *done = [[NSAlert alloc] init];
                done.alertStyle = NSAlertStyleInformational;
                done.messageText = @"增强版微信已生成";
                done.informativeText = [NSString stringWithFormat:
                    @"产物：%@\n\n请先完全退出原版微信，再启动增强版；原版不会自动退出。",
                    self.enhancedAppURL.path];
                [done addButtonWithTitle:@"好"];
                [done runModal];
            } else {
                self.statusField.textColor = [NSColor systemRedColor];
                self.statusField.stringValue = error.localizedDescription ?: @"生成失败";
                WCRWriteManagerLog([NSString stringWithFormat:@"install failed: %@",
                    error.localizedDescription ?: @"未知错误"]);
                [self appendLog:[NSString stringWithFormat:@"失败：%@",
                    error.localizedDescription ?: @"未知错误"]];
            }
        });
    });
}

- (void)launchEnhancedCopy:(id)sender {
    (void)sender;
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.enhancedAppURL.path]) return;

    NSArray<NSRunningApplication *> *running =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:kWCROriginalBundleIdentifier];
    NSMutableArray<NSRunningApplication *> *otherInstances = [NSMutableArray array];
    for (NSRunningApplication *application in running) {
        NSString *executablePath = application.executableURL.path;
        if (executablePath.length == 0) continue;
        if ([executablePath hasPrefix:self.enhancedAppURL.path]) {
            [application activateWithOptions:NSApplicationActivateIgnoringOtherApps];
            return;
        }
        [otherInstances addObject:application];
    }
    if (otherInstances.count > 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"原版微信仍在运行";
        alert.informativeText = @"请先完全退出所有微信实例，避免两个同 bundle id 的 App 争用数据目录。";
        [alert runModal];
        return;
    }

    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance = YES;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:self.enhancedAppURL
                                          configuration:configuration
                                      completionHandler:^(NSRunningApplication *app, NSError *launchError) {
        if (launchError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *alert = [[NSAlert alloc] init];
                alert.alertStyle = NSAlertStyleCritical;
                alert.messageText = @"无法启动增强版微信";
                alert.informativeText = launchError.localizedDescription;
                [alert runModal];
            });
        } else {
            [self appendLog:[NSString stringWithFormat:@"已启动: %@", app.bundleURL.path ?: self.enhancedAppURL.path]];
        }
    }];
}

- (void)revealEnhancedCopy:(id)sender {
    (void)sender;
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.enhancedAppURL.path]) return;
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[self.enhancedAppURL]];
}

@end

static void WCRPrintUsage(void) {
    fprintf(stderr,
        "WCRefine for Mac\n"
        "\n"
        "GUI:\n"
        "  WCRefine-for-Mac\n"
        "\n"
        "Diagnostics:\n"
        "  WCRefine-for-Mac --inspect <WeChat.app>\n"
        "  WCRefine-for-Mac --inject <binary> <load-path>\n"
        "  WCRefine-for-Mac --entitlements <binary>\n"
        "  WCRefine-for-Mac --install --source <WeChat.app> --output <path> "
        "--dylib <WCRefineMac.dylib> [--replace]\n"
        "                                  [--bundle-id <id>] [--display-name <name>]\n"
        "  WCRefine-for-Mac --supported\n"
        "\n"
        "多开副本：安装时传入不同的 --bundle-id（如 com.tencent.xinWeChat.WCRefineMulti2），\n"
        "副本将获得独立沙盒数据目录，可与原版微信同时运行。\n");
}

static NSString *WCRArgumentValue(NSArray<NSString *> *arguments, NSString *name) {
    NSUInteger index = [arguments indexOfObject:name];
    if (index == NSNotFound || index + 1 >= arguments.count) return nil;
    return arguments[index + 1];
}

static int WCRRunCLI(NSArray<NSString *> *arguments) {
    NSString *command = arguments.firstObject;
    NSError *error = nil;

    if ([command isEqualToString:@"--help"] || [command isEqualToString:@"-h"]) {
        WCRPrintUsage();
        return 0;
    }
    if ([command isEqualToString:@"--supported"]) {
        for (NSString *line in WCRSupportedBuildDescriptions()) {
            printf("%s\n", line.UTF8String);
        }
        return 0;
    }
    if ([command isEqualToString:@"--inspect"]) {
        if (arguments.count != 2) {
            WCRPrintUsage();
            return 2;
        }
        WCRAppInspection inspection{};
        if (!WCRInspectWeChatApp(arguments[1], &inspection, &error)) {
            fprintf(stderr, "error: %s\n", error.localizedDescription.UTF8String ?: "unknown error");
            return 2;
        }
        printf("supported=%s\nversion=%s\nbuild=%s\n",
               inspection.supported ? "yes" : "no",
               inspection.shortVersion.UTF8String ?: "",
               inspection.buildVersion.UTF8String ?: "");
        if (inspection.supported) {
            printf("state=%s\n", inspection.alreadyPatched ? "already-patched" : "pristine");
        } else if (inspection.failureReason.length) {
            printf("note=%s\n", inspection.failureReason.UTF8String);
        }
        return inspection.supported ? 0 : 1;
    }
    if ([command isEqualToString:@"--inject"]) {
        if (arguments.count != 3) {
            WCRPrintUsage();
            return 2;
        }
        if (!WCRInjectDylibLoadCommand(arguments[1], arguments[2], &error)) {
            fprintf(stderr, "error: %s\n", error.localizedDescription.UTF8String ?: "unknown error");
            return 2;
        }
        printf("ok\n");
        return 0;
    }
    if ([command isEqualToString:@"--entitlements"]) {
        if (arguments.count != 2) {
            WCRPrintUsage();
            return 2;
        }
        NSDictionary<NSString *, id> *entitlements = nil;
        if (!WCRReadExecutableEntitlements(arguments[1], &entitlements, &error)) {
            fprintf(stderr, "error: %s\n", error.localizedDescription.UTF8String ?: "unknown error");
            return 2;
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:entitlements
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
        if (!json) {
            fprintf(stderr, "error: %s\n", error.localizedDescription.UTF8String ?: "unknown error");
            return 2;
        }
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        return 0;
    }
    if ([command isEqualToString:@"--install"]) {
        NSString *source = WCRArgumentValue(arguments, @"--source");
        NSString *output = WCRArgumentValue(arguments, @"--output");
        NSString *dylib = WCRArgumentValue(arguments, @"--dylib");
        NSString *bundleIdentifier = WCRArgumentValue(arguments, @"--bundle-id");
        NSString *displayName = WCRArgumentValue(arguments, @"--display-name");
        BOOL replace = [arguments containsObject:@"--replace"];
        if (!source || !output || !dylib) {
            WCRPrintUsage();
            return 2;
        }
        BOOL succeeded = WCRInstallEnhancedCopyWithOptions(
            [NSURL fileURLWithPath:source isDirectory:YES],
            [NSURL fileURLWithPath:output isDirectory:YES],
            dylib,
            bundleIdentifier,
            displayName,
            replace,
            ^(NSString *message) {
                fprintf(stderr, "%s\n", message.UTF8String);
            },
            &error);
        if (!succeeded) {
            fprintf(stderr, "error: %s\n", error.localizedDescription.UTF8String ?: "unknown error");
            return 2;
        }
        printf("installed=%s\n", output.UTF8String);
        return 0;
    }

    WCRPrintUsage();
    return 2;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *arguments = [NSMutableArray array];
        for (int index = 1; index < argc; ++index) {
            [arguments addObject:@(argv[index])];
        }
        if (arguments.count > 0) {
            return WCRRunCLI(arguments);
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        WCRefineAppDelegate *delegate = [[WCRefineAppDelegate alloc] init];
        NSApp.delegate = delegate;
        [NSApp run];
        (void)delegate;
    }
    return 0;
}
