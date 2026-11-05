#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <mach-o/dyld.h>

#import "WCRPatchProfiles.h"
#import "WCRRecallTip.h"
#import "WCROriginalID.h"
#import "WCRFloatingID.h"
#import "WCRVoiceForward.h"
#import "WCRAvatarRound.h"
#import "WCRMessageRepeat.h"
#import "WCRCommentRepeat.h"
#import "WCRMessageCapture.h"
#import "WCRGroupLeaveMonitor.h"
#import "WCRScreenCapture.h"
#import "WCRAutoUpdate.h"
#import "WCRSessionSelect.h"
#import "WCRRecallNotify.h"
#import "WCRContactName.h"
#import "WCRContactPicker.h"
#import "WCRConfigStore.h"

#include <cstring>
#include <cstdlib>
#include <pthread.h>
#include <unistd.h>

static NSString *const kWCRDefaultsKeyAntiRevokeEnabled = @"WCRefineMacAntiRevokeEnabled";
static NSString *const kWCRDefaultsKeyRecallTipEnabled = @"WCRefineMacRecallTipEnabled";
static NSString *const kWCRDefaultsKeyRecallContentEnabled = @"WCRefineMacRecallContentEnabled";
static NSString *const kWCRDefaultsKeyOriginalIDEnabled = @"WCRefineMacOriginalIDEnabled";
static NSString *const kWCRDefaultsKeyFloatingIDEnabled = @"WCRefineMacFloatingIDEnabled";
static NSString *const kWCRDefaultsKeyVoiceForwardEnabled = @"WCRefineMacVoiceForwardEnabled";
static NSString *const kWCRDefaultsKeyMessageRepeatEnabled = @"WCRefineMacMessageRepeatEnabled";
static NSString *const kWCRDefaultsKeyCommentRepeatEnabled = @"WCRefineMacCommentRepeatEnabled";
static NSString *const kWCRDefaultsKeyAvatarRoundEnabled = @"WCRefineMacAvatarRoundEnabled";
static NSString *const kWCRDefaultsKeyGroupLeaveEnabled = @"WCRefineMacGroupLeaveEnabled";
static NSString *const kWCRDefaultsKeyScreenCaptureBypassEnabled = @"WCRefineMacScreenCaptureBypassEnabled";
static NSString *const kWCRDefaultsKeyAutoUpdateDisabled = @"WCRefineMacAutoUpdateDisabled";

/// 菜单里展示的插件版本号；随功能变更手动递增。
static NSString *const kWCRPluginVersion = @"1.0.1";

/// Menu items with a tag >= this value are rebuilt every time the submenu
/// opens (original-ID rows and the option-key diagnostics entry).
static const NSInteger kWCRDynamicItemTag = 2422600;

static os_log_t WCRLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.wcrefine.mac", "plugin");
    });
    return log;
}

@class WCRMenuController;
static WCRMenuController *gMenuController = nil;
static void WCRRefreshMenu(void);

/// 消息捕获点观察者分发：捕获模块只留一个观察者槽位，原始 ID 记录、
/// 退群监控和撤回通知都在这里转发。必须同步返回，不能把对象留到别的线程。
static void WCRMessageCaptureDispatch(const void *object) {
    WCROriginalIDObserveObject(object);
    WCRGroupLeaveOnMessage(object);
    WCRRecallNotifyObserveWrap(object);
}

static NSString *WCRRecallNotifyTargetLabel(void) {
    NSString *target = WCRRecallNotifyTargetSession();
    if (target.length == 0) return @"给自己";
    NSString *name = WCRContactNameDisplay(target);
    if (name.length == 0) name = target;
    return [target hasSuffix:@"@chatroom"]
        ? [NSString stringWithFormat:@"群 · %@", name]
        : [NSString stringWithFormat:@"联系人 · %@", name];
}

@interface WCRMenuController : NSObject <NSMenuDelegate>
@property(nonatomic, strong) NSMenuItem *toggleItem;
@property(nonatomic, strong) NSMenuItem *tipItem;
@property(nonatomic, strong) NSMenuItem *contentItem;
@property(nonatomic, strong) NSMenuItem *templateItem;
@property(nonatomic, strong) NSMenuItem *recallNotifyItem;
@property(nonatomic, strong) NSMenuItem *recallNotifySelfItem;
@property(nonatomic, strong) NSMenuItem *recallNotifyTargetItem;
@property(nonatomic, strong) NSMenu *recallNotifyTargetMenu;
@property(nonatomic, strong) NSMenuItem *recallNotifySessionItem;
@property(nonatomic, strong) NSMenuItem *recallNotifyForwardItem;
@property(nonatomic, strong) NSMenuItem *recallNotifyTemplateItem;
@property(nonatomic, strong) NSMenuItem *recallNotifyContactsItem;
@property(nonatomic, strong) NSMenuItem *recallNotifyContactsPickerItem;
@property(nonatomic, strong) NSMenuItem *voiceForwardItem;
@property(nonatomic, strong) NSMenuItem *messageRepeatItem;
@property(nonatomic, strong) NSMenuItem *commentRepeatItem;
@property(nonatomic, strong) NSMenuItem *avatarToggleItem;
@property(nonatomic, strong) NSMenu *avatarSubmenu;
@property(nonatomic, strong) NSMenuItem *avatarParentItem;
@property(nonatomic, strong) NSMenuItem *antiRevokeParentItem;
@property(nonatomic, strong) NSMenu *groupLeaveMenu;
@property(nonatomic, strong) NSMenuItem *groupLeaveParentItem;
@property(nonatomic, strong) NSMenuItem *groupLeaveItem;
@property(nonatomic, strong) NSMenuItem *groupLeaveTemplateItem;
@property(nonatomic, strong) NSMenuItem *groupLeaveNotifySessionItem;
@property(nonatomic, strong) NSMenuItem *groupLeaveNotifySelfItem;
@property(nonatomic, strong) NSMenuItem *screenCaptureItem;
@property(nonatomic, strong) NSMenuItem *autoUpdateItem;
@property(nonatomic, strong) NSMenuItem *multiOpenItem;
@property(nonatomic, strong) NSMenu *multiOpenMenu;
@property(nonatomic, strong) NSMenuItem *originalIDToggleItem;
@property(nonatomic, strong) NSMenuItem *originalIDParentItem;
@property(nonatomic, strong) NSMenuItem *petSizeItem;
@property(nonatomic, strong) NSSlider *petSizeSlider;
@property(nonatomic, strong) NSMenuItem *petHueItem;
@property(nonatomic, strong) NSSlider *petHueSlider;
@property(nonatomic, strong) NSBox *petHueSwatch;
@property(nonatomic, strong) NSMenuItem *versionItem;
@property(nonatomic, copy) NSString *versionTitlePrefix;
/// 记录最近一次活跃的窗口：菜单打开时 NSApp.mainWindow 可能为空，
/// 而用户关心的恰恰是“刚才在看的那个窗口”（比如资料页）。
@property(nonatomic, weak) NSWindow *lastActiveWindow;
- (void)ensureMenu;
- (BOOL)antiRevokeEnabled;
- (BOOL)applyConfiguredMode:(NSError **)error;
/// 圆角头像跟随偏好安装。失败不清偏好：启动时 wechat.dylib 可能还没映射。
- (BOOL)syncAvatarRound:(NSError **)error;
/// 语音转发跟随偏好安装菜单入口。关闭时卸掉。
/// wechat.dylib 还没映射时保留偏好，启动重试再装。
- (BOOL)syncVoiceForward:(NSError **)error;
/// 消息复读跟随偏好安装长按菜单 Hook。关闭时卸掉，菜单立即恢复原生。
- (BOOL)syncMessageRepeat:(NSError **)error;
/// 朋友圈评论复读跟随偏好安装评论菜单 Hook。关闭时卸掉。
- (BOOL)syncCommentRepeat:(NSError **)error;
- (BOOL)currentProfileSupportsOriginalID;
@end

/// 自定义菜单行。原生 NSMenuItem 在动作执行后会结束整个菜单跟踪；勾选项改用
/// 可交互的 view，点击时直接转发菜单项动作，菜单会继续展开。
/// 同一套行也给带子菜单、点了就关菜单的项用。标题一律从同一左边距起画；
/// 对号紧跟标题右侧，子菜单箭头留在最右，有勾没勾都不会把标题挤歪。
static const CGFloat kWCRMenuRowHeight = 28;
static const CGFloat kWCRMenuRowMinWidth = 248;
static const CGFloat kWCRMenuTitleMinX = 14;
static const CGFloat kWCRMenuContentY = 5;
static const CGFloat kWCRMenuContentHeight = 18;
static const CGFloat kWCRMenuCheckWidth = 16;
static const CGFloat kWCRMenuCheckGap = 4;
static const CGFloat kWCRMenuChevronPad = 22;
static const CGFloat kWCRMenuTrailingPad = 10;

static NSImage *WCRBlankMenuStateImage(void) {
    static NSImage *image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        image = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    });
    return image;
}

/// 关掉原生勾选列。否则 AppKit 仍会给带 state 的项预留左侧空白，
/// 自定义行的标题就会和没勾的项错开。
static void WCRHideNativeMenuStateColumn(NSMenuItem *item) {
    if (!item) return;
    NSImage *blank = WCRBlankMenuStateImage();
    item.onStateImage = blank;
    item.offStateImage = blank;
    item.mixedStateImage = blank;
}

/// macOS 14 起菜单默认把带 state 的项收成选择组。点一下之后系统会把
/// item.state 写回打开前的值，自定义行若跟着 state 画，对号就像没点到。
/// SelectAny 让每一行各自勾选，不再互相覆盖。
static void WCRUseIndependentMenuChecks(NSMenu *menu) {
    if (!menu) return;
    if (@available(macOS 14.0, *)) {
        if (menu.selectionMode != NSMenuSelectionModeSelectAny) {
            menu.selectionMode = NSMenuSelectionModeSelectAny;
        }
    }
    for (NSMenuItem *item in menu.itemArray) {
        if (item.submenu && item.submenu != menu) {
            WCRUseIndependentMenuChecks(item.submenu);
        }
    }
}

/// 行尾只留给子菜单箭头。对号跟在标题后面，不占最右一列。
static CGFloat WCRMenuRowTrailingPad(NSMenuItem *item) {
    CGFloat trailing = kWCRMenuTrailingPad;
    if (item.submenu) trailing += kWCRMenuChevronPad;
    return trailing;
}

static CGFloat WCRMenuRowAfterTitlePad(void) {
    return kWCRMenuCheckGap + kWCRMenuCheckWidth;
}

@interface WCRPersistentMenuItemRow : NSView
@property(nonatomic, weak) NSMenuItem *item;
@property(nonatomic, strong) NSTrackingArea *trackingArea;
@property(nonatomic, assign) BOOL hovered;
@property(nonatomic, assign) BOOL interceptsClicks;
@property(nonatomic, assign) BOOL dismissesMenu;
@property(nonatomic, assign) BOOL checked;
- (void)reflectItemState;
- (instancetype)initWithMenuItem:(NSMenuItem *)item;
- (instancetype)initWithMenuItem:(NSMenuItem *)item interceptsClicks:(BOOL)interceptsClicks;
- (instancetype)initWithMenuItem:(NSMenuItem *)item
                interceptsClicks:(BOOL)interceptsClicks
                   dismissesMenu:(BOOL)dismissesMenu;
- (void)performMenuItemAction;
- (void)performActionForItem:(NSMenuItem *)item;
- (NSMenuItem *)mirroredToggleItem;
- (BOOL)eventHitsChevron:(NSEvent *)event;
- (void)openSubmenu;
@end

@implementation WCRPersistentMenuItemRow

- (instancetype)initWithMenuItem:(NSMenuItem *)item {
    return [self initWithMenuItem:item interceptsClicks:YES dismissesMenu:NO];
}

- (instancetype)initWithMenuItem:(NSMenuItem *)item interceptsClicks:(BOOL)interceptsClicks {
    return [self initWithMenuItem:item interceptsClicks:interceptsClicks dismissesMenu:NO];
}

- (instancetype)initWithMenuItem:(NSMenuItem *)item
                interceptsClicks:(BOOL)interceptsClicks
                   dismissesMenu:(BOOL)dismissesMenu {
    WCRHideNativeMenuStateColumn(item);
    NSFont *font = [NSFont menuFontOfSize:0];
    CGFloat titleWidth = ceil([item.title sizeWithAttributes:@{NSFontAttributeName : font}].width);
    CGFloat trailing = WCRMenuRowTrailingPad(item);
    CGFloat width = MAX(kWCRMenuRowMinWidth,
                        kWCRMenuTitleMinX + titleWidth + WCRMenuRowAfterTitlePad() + trailing);
    self = [super initWithFrame:NSMakeRect(0, 0, width, kWCRMenuRowHeight)];
    if (!self) return nil;
    _item = item;
    _interceptsClicks = interceptsClicks;
    _dismissesMenu = dismissesMenu;
    // 对号不跟 item.state 走。macOS 14 之后菜单会把勾选态收成选择组，
    // 自定义 view 自己改完 state，跟踪结束又写回开，看起来就像点了没反应。
    _checked = item.state == NSControlStateValueOn;
    self.autoresizingMask = NSViewWidthSizable;
    return self;
}

- (void)reflectItemState {
    self.checked = self.item.state == NSControlStateValueOn;
    [self setNeedsDisplay:YES];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.trackingArea) {
        [self removeTrackingArea:self.trackingArea];
        self.trackingArea = nil;
    }
    self.trackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                     NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (NSView *)hitTest:(NSPoint)point {
    if (!self.interceptsClicks) return nil;
    return [super hitTest:point];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    self.hovered = YES;
    [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    self.hovered = NO;
    [self setNeedsDisplay:YES];
}

- (NSMenuItem *)mirroredToggleItem {
    NSMenuItem *item = self.item;
    // 父行和子菜单里的同名开关不要共用 action。macOS 14 会把相同
    // target/action 收成一组，点一次变成互斥选择，勾着就关不掉。
    // setSubmenu: 会把父行 action 写成 submenuAction:。那只是标记，不是开关动作。
    if (!item.submenu || (item.action && item.action != @selector(submenuAction:))) return nil;
    for (NSMenuItem *child in item.submenu.itemArray) {
        if (!child.action || child.submenu || child.action == @selector(submenuAction:)) continue;
        if ([child.title isEqualToString:item.title]) return child;
    }
    return nil;
}

- (BOOL)eventHitsChevron:(NSEvent *)event {
    NSMenuItem *item = self.item;
    if (!item.submenu || !event) return NO;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSMouseInRect(point, self.bounds, self.isFlipped)) return NO;
    return point.x >= NSWidth(self.bounds) - (kWCRMenuChevronPad + 6);
}

- (void)openSubmenu {
    NSMenuItem *item = self.item;
    NSMenu *submenu = item.submenu;
    NSMenu *menu = item.menu;
    if (!submenu || !menu) return;
    // 不要发 submenuAction:。它只是 setSubmenu: 写下的标记，NSMenu 没有这个实现。
    // 直接调用会 doesNotRecognizeSelector，微信把未捕获异常收成 abort。
    Ivar extraIvar = class_getInstanceVariable([NSMenu class], "_extra");
    id extra = extraIvar ? object_getIvar(menu, extraIvar) : nil;
    Ivar implIvar = extra ? class_getInstanceVariable(object_getClass(extra), "_impl") : nil;
    id impl = (extra && implIvar) ? object_getIvar(extra, implIvar) : nil;
    NSView *viewer = self;
    while (viewer && ![viewer respondsToSelector:@selector(menuItem)]) viewer = viewer.superview;
    SEL openSel = NSSelectorFromString(@"_highlightMenuItemView:shouldOpenSubmenu:");
    if (impl && viewer && [impl respondsToSelector:openSel]) {
        @try {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(impl, openSel, viewer, YES);
            return;
        } @catch (NSException *exception) {
            os_log_error(WCRLog(), "open submenu failed: %{public}@", exception);
        }
    }
    NSPoint edge = [self convertPoint:NSMakePoint(NSMaxX(self.bounds), NSMaxY(self.bounds))
                              toView:nil];
    NSPoint screen = self.window ? [self.window convertPointToScreen:edge] : [NSEvent mouseLocation];
    NSMenu *root = menu;
    while (root.supermenu) root = root.supermenu;
    [root cancelTracking];
    dispatch_async(dispatch_get_main_queue(), ^{
        [submenu popUpMenuPositioningItem:nil atLocation:screen inView:nil];
    });
}

- (void)mouseDown:(NSEvent *)event {
    NSMenuItem *item = self.item;
    if (item && !item.enabled) return;
    // 带勾的父行：点标题或对号就切换；点右侧箭头才展开格式和通知。
    // 自定义 view 会挡住系统的子菜单展开，所以箭头要自己打开。
    NSMenuItem *mirrored = [self mirroredToggleItem];
    if (item.submenu && (mirrored == nil || [self eventHitsChevron:event])) {
        [self openSubmenu];
        return;
    }
    if (mirrored) {
        [self performActionForItem:mirrored];
        [self setNeedsDisplay:YES];
        [self displayIfNeeded];
        return;
    }
    if (!self.interceptsClicks) {
        [super mouseDown:event];
        return;
    }
    [self performMenuItemAction];
    [self setNeedsDisplay:YES];
    [self displayIfNeeded];
}

- (void)performMenuItemAction {
    [self performActionForItem:self.item];
}

- (void)performActionForItem:(NSMenuItem *)item {
    if (!item.enabled || !item.action || item.action == @selector(submenuAction:)) return;
    id target = item.target ?: [NSApp targetForAction:item.action to:nil from:item];
    SEL action = item.action;
    if (![target respondsToSelector:action]) return;
    IMP implementation = [target methodForSelector:action];
    if (!implementation) return;
    void (^invoke)(void) = ^{
        ((void (*)(id, SEL, NSMenuItem *))implementation)(target, action, item);
    };
    if (self.dismissesMenu) {
        // 弹窗必须等菜单跟踪结束，否则 NSAlert / NSWindow 会贴在菜单后面或根本不出现。
        NSMenu *root = item.menu;
        if (root) {
            while (root.supermenu) root = root.supermenu;
            [root cancelTracking];
        }
        dispatch_async(dispatch_get_main_queue(), invoke);
        return;
    }
    // NSApp sendAction 会被 NSMenu 观察到并结束跟踪，开关项直接调用以保持菜单打开。
    invoke();
    // 菜单跟踪期间仅 setNeedsDisplay 不一定立即刷新；显式通知菜单并强制当前行重绘。
    if (item.menu) [item.menu itemChanged:item];
    [self setNeedsDisplay:YES];
    [self displayIfNeeded];
}

- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSString *)accessibilityRole {
    // 纯开关才报成复选框。带子菜单的父行仍是菜单项（行身切换，箭头展开）。
    if (self.interceptsClicks && !self.dismissesMenu && !self.item.submenu) {
        return NSAccessibilityCheckBoxRole;
    }
    return NSAccessibilityMenuItemRole;
}

- (NSString *)accessibilityLabel {
    return self.item.title;
}

- (id)accessibilityValue {
    return @(self.checked);
}

- (BOOL)accessibilityPerformPress {
    NSMenuItem *item = self.item;
    if (!item.enabled) return NO;
    NSMenuItem *mirrored = [self mirroredToggleItem];
    if (mirrored) {
        [self performActionForItem:mirrored];
        [self setNeedsDisplay:YES];
        return YES;
    }
    if (item.submenu) {
        [self openSubmenu];
        return YES;
    }
    if (!item.action || item.action == @selector(submenuAction:)) return NO;
    [self performMenuItemAction];
    [self setNeedsDisplay:YES];
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSMenuItem *item = self.item;
    if (!item) return;

    BOOL active = item.enabled && (self.hovered || item.isHighlighted);
    if (active) {
        [[NSColor selectedContentBackgroundColor] setFill];
        NSBezierPath *highlight = [NSBezierPath
            bezierPathWithRoundedRect:NSInsetRect(self.bounds, 3, 2)
                              xRadius:5
                              yRadius:5];
        [highlight fill];
    }

    NSColor *textColor = item.enabled
        ? (active ? [NSColor selectedMenuItemTextColor] : [NSColor labelColor])
        : [NSColor disabledControlTextColor];
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentLeft;
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName : [NSFont menuFontOfSize:0],
        NSForegroundColorAttributeName : textColor,
        NSParagraphStyleAttributeName : paragraph,
    };

    CGFloat trailing = WCRMenuRowTrailingPad(item);
    BOOL on = self.checked;
    CGFloat afterTitle = on ? WCRMenuRowAfterTitlePad() : 0;
    CGFloat titleMaxWidth = MAX(0, NSWidth(self.bounds) - kWCRMenuTitleMinX - trailing - afterTitle);
    CGFloat titleWidth = MIN(ceil([item.title sizeWithAttributes:attributes].width), titleMaxWidth);
    [item.title drawInRect:NSMakeRect(kWCRMenuTitleMinX, kWCRMenuContentY,
                                      titleWidth,
                                      kWCRMenuContentHeight)
            withAttributes:attributes];
    if (on) {
        NSMutableParagraphStyle *checkParagraph = [[NSMutableParagraphStyle alloc] init];
        checkParagraph.alignment = NSTextAlignmentCenter;
        NSDictionary<NSAttributedStringKey, id> *checkAttributes = @{
            NSFontAttributeName : [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName : textColor,
            NSParagraphStyleAttributeName : checkParagraph,
        };
        [@"✓" drawInRect:NSMakeRect(kWCRMenuTitleMinX + titleWidth + kWCRMenuCheckGap,
                                    kWCRMenuContentY,
                                    kWCRMenuCheckWidth, kWCRMenuContentHeight)
          withAttributes:checkAttributes];
    }
    if (item.submenu) {
        NSBezierPath *chevron = [NSBezierPath bezierPath];
        CGFloat x = NSWidth(self.bounds) - 16;
        CGFloat midY = NSMidY(self.bounds);
        [chevron moveToPoint:NSMakePoint(x - 4.5, midY + 5)];
        [chevron lineToPoint:NSMakePoint(x, midY)];
        [chevron lineToPoint:NSMakePoint(x - 4.5, midY - 5)];
        chevron.lineWidth = 1.4;
        chevron.lineCapStyle = NSLineCapStyleRound;
        chevron.lineJoinStyle = NSLineJoinStyleRound;
        [textColor setStroke];
        [chevron stroke];
    }
}

@end

/// 下一次开关看这一行自己画出来的勾，不看 item.state。
/// 菜单跟踪结束后系统可能把 state 拨回去，再拿它决定开或关，点了就没反应。
static BOOL WCRMenuItemChecked(NSMenuItem *item) {
    if ([item.view isKindOfClass:[WCRPersistentMenuItemRow class]]) {
        return ((WCRPersistentMenuItemRow *)item.view).checked;
    }
    return item.state == NSControlStateValueOn;
}

@implementation WCRMenuController

- (BOOL)antiRevokeEnabled {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kWCRDefaultsKeyAntiRevokeEnabled];
    return stored ? [stored boolValue] : YES;
}

- (BOOL)recallTipEnabled {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kWCRDefaultsKeyRecallTipEnabled];
    return stored ? [stored boolValue] : YES;
}

- (BOOL)recallContentEnabled {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kWCRDefaultsKeyRecallContentEnabled];
    return stored ? [stored boolValue] : YES;
}

- (BOOL)originalIDEnabled {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kWCRDefaultsKeyOriginalIDEnabled];
    return stored ? [stored boolValue] : YES;
}

- (BOOL)voiceForwardEnabled {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kWCRDefaultsKeyVoiceForwardEnabled];
    return stored ? [stored boolValue] : NO;
}

- (BOOL)messageRepeatEnabled {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kWCRDefaultsKeyMessageRepeatEnabled];
    return stored ? [stored boolValue] : NO;
}

- (BOOL)commentRepeatEnabled {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kWCRDefaultsKeyCommentRepeatEnabled];
    return stored ? [stored boolValue] : NO;
}

- (BOOL)avatarRoundEnabled {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kWCRDefaultsKeyAvatarRoundEnabled];
    return stored ? [stored boolValue] : NO;
}

- (BOOL)groupLeaveEnabled {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kWCRDefaultsKeyGroupLeaveEnabled];
    return stored ? [stored boolValue] : NO;
}

- (BOOL)screenCaptureBypassEnabled {
    id stored = [[NSUserDefaults standardUserDefaults]
        objectForKey:kWCRDefaultsKeyScreenCaptureBypassEnabled];
    return stored ? [stored boolValue] : YES;
}

- (BOOL)autoUpdateDisabled {
    id stored = [[NSUserDefaults standardUserDefaults]
        objectForKey:kWCRDefaultsKeyAutoUpdateDisabled];
    return stored ? [stored boolValue] : YES;
}

- (void)setAntiRevokeEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kWCRDefaultsKeyAntiRevokeEnabled];
}

- (void)setRecallTipEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kWCRDefaultsKeyRecallTipEnabled];
}

- (void)setRecallContentEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kWCRDefaultsKeyRecallContentEnabled];
}

- (void)setOriginalIDEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kWCRDefaultsKeyOriginalIDEnabled];
}

- (BOOL)floatingIDEnabled {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kWCRDefaultsKeyFloatingIDEnabled];
    return stored ? [stored boolValue] : YES;
}

- (void)setFloatingIDEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kWCRDefaultsKeyFloatingIDEnabled];
}

- (void)setVoiceForwardEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kWCRDefaultsKeyVoiceForwardEnabled];
}

- (void)setMessageRepeatEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kWCRDefaultsKeyMessageRepeatEnabled];
}

- (void)setCommentRepeatEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kWCRDefaultsKeyCommentRepeatEnabled];
}

- (void)setAvatarRoundEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kWCRDefaultsKeyAvatarRoundEnabled];
}

- (void)setGroupLeaveEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kWCRDefaultsKeyGroupLeaveEnabled];
}

- (void)setScreenCaptureBypassEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled
                                           forKey:kWCRDefaultsKeyScreenCaptureBypassEnabled];
}

- (void)setAutoUpdateDisabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled
                                           forKey:kWCRDefaultsKeyAutoUpdateDisabled];
}

- (BOOL)currentProfileSupportsRecallTip {
    NSError *error = nil;
    const WCRPatchProfile *profile = WCRCurrentProcessProfile(&error);
    return profile && profile->revokeParserAddress != 0 &&
           profile->revokeNewMsgIdOffset != 0 && profile->revokeReplaceMsgOffset != 0;
}

- (BOOL)currentProfileSupportsVoiceForward {
    NSError *error = nil;
    const WCRPatchProfile *profile = WCRCurrentProcessProfile(&error);
    return WCRVoiceForwardSupportsProfile(profile);
}

- (BOOL)currentProfileSupportsMessageRepeat {
    NSError *error = nil;
    return WCRMessageRepeatSupportsProfile(WCRCurrentProcessProfile(&error));
}

- (BOOL)currentProfileSupportsCommentRepeat {
    NSError *error = nil;
    return WCRCommentRepeatSupportsProfile(WCRCurrentProcessProfile(&error));
}

- (BOOL)currentProfileSupportsGroupLeave {
    NSError *error = nil;
    return WCRGroupLeaveMonitorSupportsProfile(WCRCurrentProcessProfile(&error));
}

- (BOOL)currentProfileSupportsOriginalID {
    NSError *error = nil;
    return WCRMessageCaptureSupportsProfile(WCRCurrentProcessProfile(&error));
}

/// 消息收口 Hook 的统一装/卸：撤回原文捕获、原始 ID 记录与退群监控共用
/// 同一个 messageFinalizer Hook（WCRMessageCapture 独占安装，各消费方经
/// 观察者分发器取数据），任一开启就需要它，全部关闭才卸载。
- (BOOL)syncMessageCapture:(NSError **)error {
    BOOL groupLeaveRequested = [self groupLeaveEnabled];
    BOOL groupLeaveActive = NO;
    NSError *profileError = nil;
    NSError *leaveError = nil;
    const WCRPatchProfile *profile = WCRCurrentProcessProfile(&profileError);

    if (groupLeaveRequested) {
        if (WCRGroupLeaveMonitorInstall(profile, &leaveError)) {
            groupLeaveActive = YES;
        } else {
            os_log_error(WCRLog(), "group-leave monitor install failed: %{public}@",
                         leaveError.localizedDescription ?: @"unknown");
        }
    } else {
        WCRGroupLeaveMonitorUninstall(nil);
    }
    WCRRecallNotifySetLeaveMonitorActive(groupLeaveActive);

    // 正文跟「撤回提示」开关走，不等提示钩子装上。启动后最先流过终结器的
    // 消息若只记到空正文，撤回时「撤回内容」这一行就会缺。
    BOOL tipNeedsCapture = [self antiRevokeEnabled] && [self recallTipEnabled] &&
                           profile && profile->revokeParserAddress != 0;
    // 有防撤回补丁点时，原始 ID 仍跟着防撤回开关。这一版没登记补丁点时，
    // 原始 ID 和当前会话置顶只看自己的开关，避免关掉无效的防撤回把它们一起卸掉。
    BOOL antiRevokeSite = profile && profile->patchAddress != 0;
    BOOL originalIDNeedsCapture = [self originalIDEnabled] &&
        (antiRevokeSite ? [self antiRevokeEnabled] : YES) &&
        profile && WCRMessageCaptureSupportsProfile(profile);
    // 通知借用同一条收口拍文字外壳和原消息快照。正文捕获仍只跟撤回提示走。
    BOOL notifyWanted = ((([self antiRevokeEnabled] && WCRRecallNotifyWantsCapture()) ||
                          WCRRecallNotifyLeaveWantsCapture()) &&
                         WCRRecallNotifySupportsProfile(profile));
    BOOL notifyNeedsCapture = NO;
    if (notifyWanted) {
        NSError *notifyError = nil;
        if (!WCRRecallNotifyPrepare(&notifyError)) {
            os_log_error(WCRLog(), "recall notify prepare failed: %{public}@",
                         notifyError.localizedDescription ?: @"unknown");
        }
        notifyNeedsCapture = WCRRecallNotifyIsReady();
    } else {
        WCRRecallNotifyReleaseHeldMessages();
    }
    WCRMessageCaptureSetContentCaptureEnabled(tipNeedsCapture);
    BOOL captureReady = YES;
    if (!groupLeaveActive && !tipNeedsCapture && !originalIDNeedsCapture &&
        !notifyNeedsCapture) {
        NSError *uninstallError = nil;
        if (!WCRMessageCaptureUninstall(&uninstallError)) {
            if (error) *error = uninstallError;
            captureReady = NO;
        }
    } else if (WCRMessageCaptureIsInstalled()) {
        captureReady = YES;
    } else if (!profile) {
        if (error) *error = profileError;
        captureReady = NO;
    } else {
        captureReady = WCRMessageCaptureInstall(profile, error);
    }

    // 当前窗口置顶：270135 的 OnSelectedSession。和收口 Hook 同一组开关
    // （防撤回 + 原始 ID）。字节不匹配只跳过置顶，已有记录仍然保留。
    // wechat.dylib 还没映射时跟收口 Hook 一样失败，启动重试会再装。
    if (!originalIDNeedsCapture) {
        NSError *sessionError = nil;
        if (!WCRSessionSelectUninstall(&sessionError)) {
            if (error && !*error) *error = sessionError;
            captureReady = NO;
        }
    } else if (profile && !WCRSessionSelectIsInstalled()) {
        NSError *sessionError = nil;
        if (!WCRSessionSelectInstall(profile, &sessionError)) {
            NSString *message = sessionError.localizedDescription ?: @"";
            if ([message containsString:@"尚未加载"]) {
                if (error && !*error) *error = sessionError;
                captureReady = NO;
            } else {
                os_log_error(WCRLog(), "session select hook skipped: %{public}@", message);
            }
        } else {
            os_log_info(WCRLog(), "session select hook installed");
        }
    }

    // 开关打开但监控没装上时必须失败，否则菜单勾着、记录永远是空的。
    if (groupLeaveRequested && !groupLeaveActive) {
        if (error && !*error) *error = leaveError;
        return NO;
    }
    return captureReady;
}

/// 头像圆角开着，且当前构建登记了形状绘制点时安装钩子。
/// 关着只刷新透传缓存，已装上的钩子留着（绘制前看到开关关闭就原样返回）。
/// 启动调用方忽略返回值：wechat.dylib 还没映射时保持偏好，稍后重试。
- (BOOL)syncAvatarRound:(NSError **)error {
    WCRAvatarRoundRefreshPrefs();
    if (![self avatarRoundEnabled] || WCRAvatarRoundIsInstalled()) return YES;
    NSError *installError = nil;
    if (WCRAvatarRoundInstall(&installError)) return YES;
    NSString *message = installError.localizedDescription ?: @"";
    if ([message containsString:@"尚未加载"]) {
        os_log_debug(WCRLog(), "avatar round waiting for wechat.dylib");
    } else {
        os_log_error(WCRLog(), "avatar round install failed: %{public}@", message);
    }
    if (error) *error = installError;
    return NO;
}

/// 语音转发开着就安装菜单入口钩子，关掉就卸掉。
/// 启动时 wechat.dylib 可能还没映射，这种失败保留偏好。
- (BOOL)syncVoiceForward:(NSError **)error {
    // 消息复读也要经过微信的原生消息菜单。语音消息的原生菜单入口由同一个
    // 门控打开：复读已安装时即使“语音转发”独立开关关闭，也必须保留这项
    // 门控，否则语音消息不会出现长按菜单。
    BOOL repeatNeedsVoiceMenu = [self messageRepeatEnabled] &&
                                WCRMessageRepeatIsInstalled();
    if (![self voiceForwardEnabled] && !repeatNeedsVoiceMenu) {
        return WCRVoiceForwardUninstall(error);
    }
    if (WCRVoiceForwardIsInstalled()) return YES;
    NSError *profileError = nil;
    const WCRPatchProfile *profile = WCRCurrentProcessProfile(&profileError);
    if (!profile) {
        if (error) *error = profileError;
        return NO;
    }
    return WCRVoiceForwardInstall(profile, error);
}

/// 消息复读打开时安装长按菜单 Hook；关闭时恢复原生菜单。
/// 启动早期 wechat.dylib 还没映射时保留偏好，由启动重试补装。
- (BOOL)syncMessageRepeat:(NSError **)error {
    if (![self messageRepeatEnabled]) {
        if (!WCRMessageRepeatUninstall(error)) return NO;
        return [self syncVoiceForward:error];
    }

    if (!WCRMessageRepeatIsInstalled()) {
        NSError *profileError = nil;
        const WCRPatchProfile *profile = WCRCurrentProcessProfile(&profileError);
        if (!profile) {
            if (error) *error = profileError;
            return NO;
        }
        if (!WCRMessageRepeatInstall(profile, error)) return NO;
    }
    // 语音消息的菜单可见性由 WCRVoiceForward 的门控负责。复读开启时也要求
    // 这个门控存在，但不改变“启用语音转发”的独立偏好。
    return [self syncVoiceForward:error];
}

/// 朋友圈评论复读打开时安装评论菜单 Hook；关闭时恢复原生菜单。
/// 启动早期 wechat.dylib 还没映射时保留偏好，由启动重试补装。
- (BOOL)syncCommentRepeat:(NSError **)error {
    if (![self commentRepeatEnabled]) {
        return WCRCommentRepeatUninstall(error);
    }
    if (WCRCommentRepeatIsInstalled()) return YES;
    NSError *profileError = nil;
    const WCRPatchProfile *profile = WCRCurrentProcessProfile(&profileError);
    if (!profile) {
        if (error) *error = profileError;
        return NO;
    }
    return WCRCommentRepeatInstall(profile, error);
}

- (WCRPatchState)currentState {
    if (WCRRecallTipIsInstalled()) return WCRPatchStateApplied;
    NSError *error = nil;
    return WCRCurrentProcessPatchState(&error);
}

- (BOOL)applyConfiguredMode:(NSError **)error {
    if (![self antiRevokeEnabled]) {
        if (!WCRRecallTipUninstall(error)) return NO;
        // 退群监控独立于防撤回开关：收口 Hook 是否保留交给 sync 统一裁决。
        if (![self syncMessageCapture:error]) return NO;
        return WCRRestoreAntiRevokePatch(error);
    }

    NSError *operationError = nil;
    const WCRPatchProfile *profile = WCRCurrentProcessProfile(&operationError);
    if (!profile) {
        if (error) *error = operationError;
        return NO;
    }

    if ([self recallTipEnabled] && profile->revokeParserAddress != 0) {
        // Tip mode must run the real parser, so first remove the silent guard patch.
        if (!WCRRestoreAntiRevokePatch(&operationError)) {
            if (error) *error = operationError;
            return NO;
        }
        if (WCRRecallTipInstall(profile, &operationError)) {
            // 收口 Hook 服务撤回原文捕获与退群监控，统一由 sync 装/卸；
            // 只是增强：失败不影响防撤回。
            [self syncMessageCapture:nil];
            return YES;
        }

        NSError *tipError = operationError;
        os_log_error(WCRLog(), "recall tip install failed: %{public}@",
                     tipError.localizedDescription ?: @"unknown");
        WCRRecallTipUninstall(nil);
        if (!WCRApplyAntiRevokePatch(&operationError)) {
            if (error) *error = operationError ?: tipError;
            return NO;
        }
        if (error) *error = tipError;
        return NO;
    }

    if (!WCRRecallTipUninstall(&operationError)) {
        if (error) *error = operationError;
        return NO;
    }
    BOOL ok = WCRApplyAntiRevokePatch(error);
    // 收口 Hook（撤回原文捕获/原始 ID 记录/退群监控共用）由 sync 统一装/卸。
    [self syncMessageCapture:nil];
    return ok;
}

- (NSMenuItem *)persistentMenuItemWithTitle:(NSString *)title
                                     action:(SEL)action
                                       menu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    WCRHideNativeMenuStateColumn(item);
    // 开关项保持菜单展开，方便连续调整多个功能；重新打开菜单时仍会从偏好同步。
    item.view = [[WCRPersistentMenuItemRow alloc] initWithMenuItem:item];
    [menu addItem:item];
    return item;
}

- (void)attachAlignedRowToItem:(NSMenuItem *)item {
    if (!item || item.isSeparatorItem) return;
    WCRHideNativeMenuStateColumn(item);
    if (item.view) return;
    // 有自定义 view 的项，AppKit 不会发 action，也不会自动展开子菜单。
    // hitTest 再返回 nil 时，微信带搜索框的菜单点了没反应：带勾的父行关不掉。
    // 命令行（有动作、无子菜单）拦截后先收菜单再异步执行。
    // 子菜单行自己接点击：同名开关点行身切换，箭头或其余父行展开子菜单。
    BOOL command = item.action && !item.submenu;
    BOOL handleClick = command || item.submenu != nil;
    item.view = [[WCRPersistentMenuItemRow alloc] initWithMenuItem:item
                                                  interceptsClicks:handleClick
                                                     dismissesMenu:command];
}

- (void)attachAlignedRowsInMenu:(NSMenu *)menu {
    if (!menu) return;
    for (NSMenuItem *item in menu.itemArray) {
        [self attachAlignedRowToItem:item];
        if (item.submenu) [self attachAlignedRowsInMenu:item.submenu];
    }
}

- (void)refreshAlignedRowsInMenu:(NSMenu *)menu {
    if (!menu) return;
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.view isKindOfClass:[WCRPersistentMenuItemRow class]]) {
            [(WCRPersistentMenuItemRow *)item.view reflectItemState];
        }
        if (item.submenu) [self refreshAlignedRowsInMenu:item.submenu];
    }
}

- (void)refreshPersistentMenuItemViews {
    [self refreshAlignedRowsInMenu:self.antiRevokeParentItem.menu];
}

- (void)ensureMenu {
    NSMenu *mainMenu = [NSApp mainMenu];
    if (!mainMenu) return;

    NSMenuItem *existing = nil;
    for (NSMenuItem *item in mainMenu.itemArray) {
        if ([item.title isEqualToString:@"WCRefine"]) {
            existing = item;
            break;
        }
    }
    if (existing) {
        [self refreshState];
        return;
    }

    NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"WCRefine"];
    submenu.delegate = self;
    submenu.autoenablesItems = NO;

    // 防撤回：二级菜单收纳主开关与提示子选项，顶层保持一行。
    NSMenu *antiRevokeMenu = [[NSMenu alloc] initWithTitle:@"启用消息防撤回"];
    antiRevokeMenu.delegate = self;

    self.toggleItem = [self persistentMenuItemWithTitle:@"启用消息防撤回"
                                                 action:@selector(toggleAntiRevoke:)
                                                   menu:antiRevokeMenu];

    self.tipItem = [self persistentMenuItemWithTitle:@"显示撤回提示"
                                              action:@selector(toggleRecallTip:)
                                                menu:antiRevokeMenu];

    self.contentItem = [self persistentMenuItemWithTitle:@"显示撤回内容"
                                                  action:@selector(toggleRecallContent:)
                                                    menu:antiRevokeMenu];

    self.templateItem = [[NSMenuItem alloc] initWithTitle:@"自定义撤回格式…"
                                                   action:@selector(editRecallTemplate:)
                                            keyEquivalent:@""];
    self.templateItem.target = self;
    [antiRevokeMenu addItem:self.templateItem];

    [antiRevokeMenu addItem:[NSMenuItem separatorItem]];

    self.recallNotifyItem = [self persistentMenuItemWithTitle:@"启用撤回消息通知"
                                                       action:@selector(toggleRecallNotify:)
                                                         menu:antiRevokeMenu];

    self.recallNotifySelfItem = [self persistentMenuItemWithTitle:@"通知给自己"
                                                           action:@selector(toggleRecallNotifySelf:)
                                                             menu:antiRevokeMenu];

    NSMenu *notifyTargetMenu = [[NSMenu alloc] initWithTitle:@"接收会话"];
    notifyTargetMenu.delegate = self;
    notifyTargetMenu.autoenablesItems = NO;
    self.recallNotifyTargetMenu = notifyTargetMenu;
    NSMenuItem *notifyTargetItem = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"接收会话：%@", WCRRecallNotifyTargetLabel()]
              action:nil
       keyEquivalent:@""];
    notifyTargetItem.submenu = notifyTargetMenu;
    self.recallNotifyTargetItem = notifyTargetItem;
    [antiRevokeMenu addItem:notifyTargetItem];

    self.recallNotifySessionItem = [self persistentMenuItemWithTitle:@"通知当前会话"
                                                              action:@selector(toggleRecallNotifySession:)
                                                                menu:antiRevokeMenu];

    self.recallNotifyForwardItem = [self persistentMenuItemWithTitle:@"转发原消息给自己"
                                                              action:@selector(toggleRecallNotifyForward:)
                                                                menu:antiRevokeMenu];

    self.recallNotifyTemplateItem = [[NSMenuItem alloc] initWithTitle:@"自定义通知格式…"
                                                               action:@selector(editRecallNotifyTemplate:)
                                                        keyEquivalent:@""];
    self.recallNotifyTemplateItem.target = self;
    [antiRevokeMenu addItem:self.recallNotifyTemplateItem];

    self.recallNotifyContactsItem = [self persistentMenuItemWithTitle:@"通知指定联系人"
                                                                action:@selector(toggleNotifyContacts:)
                                                                  menu:antiRevokeMenu];

    self.recallNotifyContactsPickerItem = [[NSMenuItem alloc] initWithTitle:@"选择通知联系人…"
                                                                      action:@selector(presentNotifyContacts:)
                                                               keyEquivalent:@""];
    self.recallNotifyContactsPickerItem.target = self;
    [antiRevokeMenu addItem:self.recallNotifyContactsPickerItem];

    NSMenuItem *antiRevokeParent = [[NSMenuItem alloc] initWithTitle:@"启用消息防撤回"
                                                              action:nil
                                                       keyEquivalent:@""];
    self.antiRevokeParentItem = antiRevokeParent;
    antiRevokeParent.submenu = antiRevokeMenu;
    [submenu addItem:antiRevokeParent];

    [submenu addItem:[NSMenuItem separatorItem]];

    // 宠物大小必须在创建菜单时就放进子菜单。menuNeedsUpdate 里临时插入的行
    // 在这个带搜索框的菜单里不会出现，所以不能再插在开关下面。
    NSMenu *originalIDMenu = [[NSMenu alloc] initWithTitle:@"启用原始ID查询"];
    originalIDMenu.delegate = self;
    originalIDMenu.autoenablesItems = NO;

    self.originalIDToggleItem = [self persistentMenuItemWithTitle:@"启用原始ID查询"
                                                           action:@selector(toggleOriginalID:)
                                                             menu:originalIDMenu];
    [originalIDMenu addItem:[NSMenuItem separatorItem]];

    // 这一行本身就是滑杆，打开子菜单就能拖。不要再做成点开弹窗的标题。
    // 子视图必须用 frame：labelWithString 会关掉 autoresizing，这一行会变成空白。
    NSView *petSizeRow = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 248, 30)];
    petSizeRow.translatesAutoresizingMaskIntoConstraints = YES;

    NSTextField *petSizeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(14, 6, 64, 18)];
    petSizeLabel.translatesAutoresizingMaskIntoConstraints = YES;
    petSizeLabel.stringValue = @"宠物大小";
    petSizeLabel.editable = NO;
    petSizeLabel.selectable = NO;
    petSizeLabel.bezeled = NO;
    petSizeLabel.drawsBackground = NO;
    petSizeLabel.font = [NSFont menuFontOfSize:0];
    petSizeLabel.textColor = [NSColor labelColor];

    NSSlider *petSizeSlider = [NSSlider sliderWithTarget:self
                                                  action:@selector(slideFloatingIDSize:)];
    petSizeSlider.translatesAutoresizingMaskIntoConstraints = YES;
    petSizeSlider.frame = NSMakeRect(80, 4, 124, 22);
    petSizeSlider.minValue = 9;
    petSizeSlider.maxValue = 28;
    petSizeSlider.doubleValue = WCRFloatingIDFontSize();
    petSizeSlider.continuous = YES;
    petSizeSlider.controlSize = NSControlSizeSmall;
    petSizeSlider.autoresizingMask = NSViewWidthSizable;
    self.petSizeSlider = petSizeSlider;

    NSTextField *petSizeValue = [[NSTextField alloc] initWithFrame:NSMakeRect(208, 6, 32, 18)];
    petSizeValue.translatesAutoresizingMaskIntoConstraints = YES;
    petSizeValue.tag = 91;
    petSizeValue.stringValue = [NSString stringWithFormat:@"%.0f", WCRFloatingIDFontSize()];
    petSizeValue.editable = NO;
    petSizeValue.selectable = NO;
    petSizeValue.bezeled = NO;
    petSizeValue.drawsBackground = NO;
    petSizeValue.alignment = NSTextAlignmentRight;
    petSizeValue.font = [NSFont menuFontOfSize:0];
    petSizeValue.textColor = [NSColor labelColor];
    petSizeValue.autoresizingMask = NSViewMinXMargin;

    [petSizeRow addSubview:petSizeLabel];
    [petSizeRow addSubview:petSizeSlider];
    [petSizeRow addSubview:petSizeValue];

    self.petSizeItem = [[NSMenuItem alloc] initWithTitle:@"宠物大小"
                                                  action:nil
                                           keyEquivalent:@""];
    self.petSizeItem.view = petSizeRow;
    [originalIDMenu addItem:self.petSizeItem];

    // 颜色也是这一行上的滑杆，拖的时候身体跟着变色。色块用 NSBox 画，菜单里才看得见。
    NSView *petHueRow = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 248, 30)];
    petHueRow.translatesAutoresizingMaskIntoConstraints = YES;

    NSTextField *petHueLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(14, 6, 64, 18)];
    petHueLabel.translatesAutoresizingMaskIntoConstraints = YES;
    petHueLabel.stringValue = @"宠物颜色";
    petHueLabel.editable = NO;
    petHueLabel.selectable = NO;
    petHueLabel.bezeled = NO;
    petHueLabel.drawsBackground = NO;
    petHueLabel.font = [NSFont menuFontOfSize:0];
    petHueLabel.textColor = [NSColor labelColor];

    NSSlider *petHueSlider = [NSSlider sliderWithTarget:self
                                                 action:@selector(slideFloatingIDHue:)];
    petHueSlider.translatesAutoresizingMaskIntoConstraints = YES;
    petHueSlider.frame = NSMakeRect(80, 4, 124, 22);
    petHueSlider.minValue = 0;
    petHueSlider.maxValue = 360;
    petHueSlider.doubleValue = WCRFloatingIDHue();
    petHueSlider.continuous = YES;
    petHueSlider.controlSize = NSControlSizeSmall;
    petHueSlider.autoresizingMask = NSViewWidthSizable;
    self.petHueSlider = petHueSlider;

    NSBox *petHueSwatch = [[NSBox alloc] initWithFrame:NSMakeRect(212, 6, 18, 18)];
    petHueSwatch.translatesAutoresizingMaskIntoConstraints = YES;
    petHueSwatch.boxType = NSBoxCustom;
    petHueSwatch.titlePosition = NSNoTitle;
    petHueSwatch.borderWidth = 1;
    petHueSwatch.cornerRadius = 4;
    petHueSwatch.contentViewMargins = NSMakeSize(0, 0);
    petHueSwatch.fillColor = WCRFloatingIDHueColor(WCRFloatingIDHue());
    petHueSwatch.borderColor = [NSColor separatorColor];
    petHueSwatch.autoresizingMask = NSViewMinXMargin;
    self.petHueSwatch = petHueSwatch;

    [petHueRow addSubview:petHueLabel];
    [petHueRow addSubview:petHueSlider];
    [petHueRow addSubview:petHueSwatch];

    self.petHueItem = [[NSMenuItem alloc] initWithTitle:@"宠物颜色"
                                                 action:nil
                                          keyEquivalent:@""];
    self.petHueItem.view = petHueRow;
    [originalIDMenu addItem:self.petHueItem];

    NSMenuItem *originalIDParent = [[NSMenuItem alloc] initWithTitle:@"启用原始ID查询"
                                                              action:nil
                                                       keyEquivalent:@""];
    self.originalIDParentItem = originalIDParent;
    originalIDParent.submenu = originalIDMenu;
    [submenu addItem:originalIDParent];

    self.voiceForwardItem = [self persistentMenuItemWithTitle:@"启用语音转发"
                                                       action:@selector(toggleVoiceForward:)
                                                         menu:submenu];

    self.messageRepeatItem = [self persistentMenuItemWithTitle:@"启用消息复读"
                                                        action:@selector(toggleMessageRepeat:)
                                                          menu:submenu];
    self.commentRepeatItem = [self persistentMenuItemWithTitle:@"启用朋友圈评论复读"
                                                        action:@selector(toggleCommentRepeat:)
                                                          menu:submenu];

    // 圆角头像：二级菜单 = 开关 + 圆角大小预设（勾选当前档位）。
    NSMenu *avatarMenu = [[NSMenu alloc] initWithTitle:@"启用圆角头像"];
    avatarMenu.delegate = self;
    avatarMenu.autoenablesItems = NO;

    self.avatarToggleItem = [self persistentMenuItemWithTitle:@"启用圆角头像"
                                                       action:@selector(toggleAvatarRound:)
                                                         menu:avatarMenu];

    [avatarMenu addItem:[NSMenuItem separatorItem]];

    self.avatarSubmenu = avatarMenu;
    NSMenuItem *avatarParent = [[NSMenuItem alloc] initWithTitle:@"启用圆角头像"
                                                          action:nil
                                                   keyEquivalent:@""];
    self.avatarParentItem = avatarParent;
    avatarParent.submenu = avatarMenu;
    [submenu addItem:avatarParent];

    // 退群监控：二级菜单 = 灰字提示开关 + 格式 + 可选文字通知去向。
    NSMenu *groupLeaveMenu = [[NSMenu alloc] initWithTitle:@"启用退群监控"];
    groupLeaveMenu.delegate = self;
    groupLeaveMenu.autoenablesItems = NO;
    self.groupLeaveMenu = groupLeaveMenu;

    self.groupLeaveItem = [self persistentMenuItemWithTitle:@"启用退群监控"
                                                     action:@selector(toggleGroupLeave:)
                                                       menu:groupLeaveMenu];
    [groupLeaveMenu addItem:[NSMenuItem separatorItem]];

    self.groupLeaveTemplateItem = [[NSMenuItem alloc]
        initWithTitle:@"自定义退群格式…"
               action:@selector(editGroupLeaveTemplate:)
        keyEquivalent:@""];
    self.groupLeaveTemplateItem.target = self;
    [groupLeaveMenu addItem:self.groupLeaveTemplateItem];
    [groupLeaveMenu addItem:[NSMenuItem separatorItem]];

    self.groupLeaveNotifySessionItem =
        [self persistentMenuItemWithTitle:@"发送通知到当前群"
                                   action:@selector(toggleGroupLeaveNotifySession:)
                                     menu:groupLeaveMenu];

    self.groupLeaveNotifySelfItem =
        [self persistentMenuItemWithTitle:@"发送通知给自己"
                                   action:@selector(toggleGroupLeaveNotifySelf:)
                                     menu:groupLeaveMenu];

    NSMenuItem *groupLeaveParent = [[NSMenuItem alloc] initWithTitle:@"启用退群监控"
                                                              action:nil
                                                       keyEquivalent:@""];
    self.groupLeaveParentItem = groupLeaveParent;
    groupLeaveParent.submenu = groupLeaveMenu;
    [submenu addItem:groupLeaveParent];

    self.screenCaptureItem = [self persistentMenuItemWithTitle:@"禁用截图检测"
                                                        action:@selector(toggleScreenCaptureBypass:)
                                                          menu:submenu];

    self.autoUpdateItem = [self persistentMenuItemWithTitle:@"禁用微信更新"
                                                     action:@selector(toggleAutoUpdate:)
                                                       menu:submenu];

    // 配置在创建菜单时放进去。带搜索框的菜单不会显示
    // menuNeedsUpdate 里临时插入的行。
    NSMenu *configMenu = [[NSMenu alloc] initWithTitle:@"插件配置管理"];
    configMenu.delegate = self;
    configMenu.autoenablesItems = NO;
    NSMenuItem *exportItem = [[NSMenuItem alloc] initWithTitle:@"导出配置"
                                                        action:@selector(exportConfig:)
                                                 keyEquivalent:@""];
    exportItem.target = self;
    [configMenu addItem:exportItem];
    NSMenuItem *importItem = [[NSMenuItem alloc] initWithTitle:@"导入配置"
                                                        action:@selector(importConfig:)
                                                 keyEquivalent:@""];
    importItem.target = self;
    [configMenu addItem:importItem];
    NSMenuItem *configParent = [[NSMenuItem alloc] initWithTitle:@"插件配置管理" action:nil keyEquivalent:@""];
    configParent.submenu = configMenu;
    [submenu addItem:configParent];

    // 启用微信多开：子菜单直接选要再开几个，点了就拉起对应数量的多开副本。
    self.multiOpenMenu = [[NSMenu alloc] initWithTitle:@"启用微信多开"];
    self.multiOpenMenu.delegate = self;
    self.multiOpenMenu.autoenablesItems = NO;
    for (NSInteger count = 1; count <= 5; ++count) {
        NSMenuItem *countItem = [[NSMenuItem alloc]
            initWithTitle:[NSString stringWithFormat:@"多开 %ld 个微信", (long)count]
                   action:@selector(launchMultiInstances:)
            keyEquivalent:@""];
        countItem.target = self;
        countItem.representedObject = @(count);
        [self.multiOpenMenu addItem:countItem];
    }
    self.multiOpenItem = [[NSMenuItem alloc] initWithTitle:@"启用微信多开" action:nil keyEquivalent:@""];
    self.multiOpenItem.submenu = self.multiOpenMenu;
    [submenu addItem:self.multiOpenItem];

    NSMenu *updateMenu = [[NSMenu alloc] initWithTitle:@"获取新版插件"];
    updateMenu.delegate = self;
    NSMenuItem *githubItem = [[NSMenuItem alloc] initWithTitle:@"从 GitHub 获取"
                                                        action:@selector(openUpdateLink:)
                                                 keyEquivalent:@""];
    githubItem.target = self;
    githubItem.representedObject = [NSURL URLWithString:@"https://github.com/plumblossom26/WCRefine-For-Mac"];
    githubItem.toolTip = @"plumblossom26/WCRefine-For-Mac";
    [updateMenu addItem:githubItem];

    NSMenuItem *channelItem = [[NSMenuItem alloc] initWithTitle:@"从 Telegram 获取"
                                                         action:@selector(openUpdateLink:)
                                                  keyEquivalent:@""];
    channelItem.target = self;
    channelItem.representedObject = [NSURL URLWithString:@"https://t.me/WCRefine"];
    channelItem.toolTip = @"@WCRefine";
    [updateMenu addItem:channelItem];

    NSMenuItem *updateItem = [[NSMenuItem alloc] initWithTitle:@"获取新版插件"
                                                        action:nil
                                                 keyEquivalent:@""];
    updateItem.submenu = updateMenu;
    [submenu addItem:updateItem];

    [submenu addItem:[NSMenuItem separatorItem]];

    NSBundle *bundle = [NSBundle mainBundle];
    NSString *shortVersion = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *buildVersion = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
    self.versionTitlePrefix = [NSString stringWithFormat:@"微信 %@（%@）· 插件 %@",
                                                        shortVersion, buildVersion, kWCRPluginVersion];
    self.versionItem = [[NSMenuItem alloc]
        initWithTitle:[self.versionTitlePrefix stringByAppendingString:@"（检查中…）"]
               action:nil
        keyEquivalent:@""];
    self.versionItem.enabled = NO;
    [submenu addItem:self.versionItem];

    NSMenuItem *topItem = [[NSMenuItem alloc] initWithTitle:@"WCRefine" action:nil keyEquivalent:@""];
    topItem.submenu = submenu;
    [mainMenu addItem:topItem];
    [self attachAlignedRowsInMenu:submenu];

    os_log_info(WCRLog(), "WCRefine menu installed (items=%lu)", (unsigned long)mainMenu.numberOfItems);

    static dispatch_once_t windowTrackingOnce;
    dispatch_once(&windowTrackingOnce, ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        NSOperationQueue *queue = [NSOperationQueue mainQueue];
        [center addObserverForName:NSWindowDidBecomeMainNotification
                            object:nil
                             queue:queue
                        usingBlock:^(NSNotification *note) {
            if (note.object) gMenuController.lastActiveWindow = note.object;
                        }];
        [center addObserverForName:NSWindowDidBecomeKeyNotification
                            object:nil
                             queue:queue
                        usingBlock:^(NSNotification *note) {
            if (note.object) gMenuController.lastActiveWindow = note.object;
                        }];
    });

    [self refreshState];
}

- (void)menuWillOpen:(NSMenu *)menu {
    // 自定义行可能保留上次打开时的绘制状态；每次展开前都从偏好重新同步，
    // 避免“偏好已关，菜单仍全勾”的假状态。
    (void)menu;
    [self refreshState];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    for (NSMenuItem *item in [menu.itemArray copy]) {
        if (item.tag >= kWCRDynamicItemTag) [menu removeItem:item];
    }

    // 圆角头像二级菜单：重建圆角大小预设行，勾选当前档位。
    if (menu == self.avatarSubmenu) {
        NSInteger current = WCRAvatarRoundRadiusPercent();
        const NSArray<NSDictionary<NSString *, id> *> *presets = @[
            @{@"percent": @0,  @"label": @"直角（0%）"},
            @{@"percent": @25, @"label": @"小圆角（25%）"},
            @{@"percent": @50, @"label": @"中圆角（50%）"},
            @{@"percent": @75, @"label": @"大圆角（75%）"},
            @{@"percent": @100, @"label": @"纯圆（100%）"},
        ];
        for (NSDictionary<NSString *, id> *preset in presets) {
            NSMenuItem *row = [self persistentMenuItemWithTitle:preset[@"label"]
                                                         action:@selector(setAvatarRadiusFromMenu:)
                                                           menu:menu];
            row.representedObject = preset[@"percent"];
            row.state = ([preset[@"percent"] integerValue] == current)
                ? NSControlStateValueOn : NSControlStateValueOff;
            row.tag = kWCRDynamicItemTag;
        }
        [self attachAlignedRowsInMenu:menu];
        [self refreshState];
        return;
    }

    // 接收会话：默认给自己，也可以从最近见过的会话里选群或联系人。
    if (menu == self.recallNotifyTargetMenu) {
        NSString *selected = WCRRecallNotifyTargetSession();
        BOOL selectedAdded = selected.length == 0;

        NSMenuItem *selfRow = [self persistentMenuItemWithTitle:@"给自己（默认）"
                                                         action:@selector(selectRecallNotifyTarget:)
                                                           menu:menu];
        selfRow.representedObject = @"";
        selfRow.state = selected.length == 0 ? NSControlStateValueOn : NSControlStateValueOff;
        selfRow.tag = kWCRDynamicItemTag;

        NSString *front = WCROriginalIDFrontValue();
        if (front.length) {
            NSString *frontName = WCRContactNameDisplay(front);
            if (frontName.length == 0) frontName = front;
            NSString *frontKind = [front hasSuffix:@"@chatroom"] ? @"群" : @"联系人";
            NSMenuItem *frontRow = [self persistentMenuItemWithTitle:
                [NSString stringWithFormat:@"当前会话 · %@ · %@", frontKind, frontName]
                                                             action:@selector(selectRecallNotifyTarget:)
                                                               menu:menu];
            frontRow.representedObject = front;
            frontRow.toolTip = front;
            frontRow.state = [front isEqualToString:selected]
                ? NSControlStateValueOn : NSControlStateValueOff;
            frontRow.tag = kWCRDynamicItemTag;
            if ([front isEqualToString:selected]) selectedAdded = YES;
        }

        NSMenuItem *recentSeparator = [NSMenuItem separatorItem];
        recentSeparator.tag = kWCRDynamicItemTag;
        [menu addItem:recentSeparator];

        for (NSDictionary<NSString *, NSString *> *record in WCROriginalIDRecentSessions()) {
            NSString *value = record[@"value"];
            if (![value isKindOfClass:[NSString class]] || value.length == 0) continue;
            if (front.length && [value isEqualToString:front]) continue;
            NSString *name = WCRContactNameDisplay(value);
            if (name.length == 0) name = value;
            NSString *kind = record[@"kind"] ?: @"会话";
            NSString *seen = record[@"lastSeen"] ?: @"";
            NSString *title = seen.length
                ? [NSString stringWithFormat:@"%@ · %@ · %@", kind, name, seen]
                : [NSString stringWithFormat:@"%@ · %@", kind, name];
            NSMenuItem *row = [self persistentMenuItemWithTitle:title
                                                         action:@selector(selectRecallNotifyTarget:)
                                                           menu:menu];
            row.representedObject = value;
            row.toolTip = value;
            row.state = [value isEqualToString:selected]
                ? NSControlStateValueOn : NSControlStateValueOff;
            row.tag = kWCRDynamicItemTag;
            if ([value isEqualToString:selected]) selectedAdded = YES;
        }

        if (!selectedAdded) {
            NSString *name = WCRContactNameDisplay(selected);
            if (name.length == 0) name = selected;
            NSMenuItem *row = [self persistentMenuItemWithTitle:
                [NSString stringWithFormat:@"当前 · %@", name]
                                                         action:@selector(selectRecallNotifyTarget:)
                                                           menu:menu];
            row.representedObject = selected;
            row.toolTip = selected;
            row.state = NSControlStateValueOn;
            row.tag = kWCRDynamicItemTag;
        }

        NSMenuItem *manualSeparator = [NSMenuItem separatorItem];
        manualSeparator.tag = kWCRDynamicItemTag;
        [menu addItem:manualSeparator];

        NSMenuItem *manual = [[NSMenuItem alloc]
            initWithTitle:@"手动输入会话 ID…"
                  action:@selector(promptRecallNotifyTarget:)
           keyEquivalent:@""];
        manual.target = self;
        manual.tag = kWCRDynamicItemTag;
        [menu addItem:manual];
        [self attachAlignedRowsInMenu:menu];
        [self refreshState];
        return;
    }

    // 语音转发：菜单入口还没登记时置灰，并说明原因。不把项点亮。
    if (![self currentProfileSupportsVoiceForward]) {
        NSInteger voiceIndex = [menu indexOfItem:self.voiceForwardItem];
        if (voiceIndex != NSNotFound) {
            NSMenuItem *hint = [[NSMenuItem alloc]
                initWithTitle:@"语音转发待适配：当前构建还没有登记发送入口"
                          action:nil
                   keyEquivalent:@""];
            hint.enabled = NO;
            hint.tag = kWCRDynamicItemTag;
            [menu insertItem:hint atIndex:voiceIndex + 1];
        }
    }

    [self attachAlignedRowsInMenu:menu];
    [self refreshState];
}

- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item {
    (void)item;
    for (NSMenuItem *row in menu.itemArray) {
        if ([row.view isKindOfClass:[WCRPersistentMenuItemRow class]]) {
            [row.view setNeedsDisplay:YES];
        }
    }
}

#pragma mark - 退群监控

- (void)toggleScreenCaptureBypass:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    [self setScreenCaptureBypassEnabled:enable];
    WCRScreenCaptureSetBypassEnabled(enable);
    [self refreshState];
    os_log_info(WCRLog(), "screen-capture bypass changed enabled=%{public}d", enable ? 1 : 0);
}

- (void)toggleAutoUpdate:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    [self setAutoUpdateDisabled:enable];
    WCRAutoUpdateSetEnabled(enable);
    [self refreshState];
    os_log_info(WCRLog(), "auto-update block changed enabled=%{public}d", enable ? 1 : 0);
}

- (void)toggleGroupLeave:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    [self setGroupLeaveEnabled:enable];
    // 收口 Hook 由消息捕获模块独占，退群监控经观察者分发器复用；装/卸
    // 统一由 sync 裁决（撤回原文捕获/原始 ID 记录可能仍需要 Hook）。
    NSError *error = nil;
    BOOL ok = [self syncMessageCapture:&error];
    if (enable && !ok) {
        // 先关掉偏好再同步一次，避免 Install 已置位但收口 Hook 没装上。
        [self setGroupLeaveEnabled:NO];
        [self syncMessageCapture:nil];
        [self showFailureTitle:@"无法开启退群监控" error:error];
    }
    [self refreshState];
    os_log_info(WCRLog(), "group leave monitor changed enabled=%{public}d", enable ? 1 : 0);
}

- (void)applyGroupLeaveNotifyChange:(BOOL)enabling
                       failureTitle:(NSString *)title
                             revert:(void (^)(void))revert {
    if (enabling && [self groupLeaveEnabled]) {
        NSError *error = nil;
        if (!WCRRecallNotifyPrepare(&error)) {
            NSString *message = error.localizedDescription ?: @"";
            if (![message containsString:@"尚未加载"]) {
                if (revert) revert();
                [self syncMessageCapture:nil];
                [self showFailureTitle:title error:error];
                [self refreshState];
                return;
            }
        }
    }
    [self refreshState];
}

- (void)toggleGroupLeaveNotifySession:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    WCRRecallNotifySetLeaveSessionEnabled(enable);
    [self applyGroupLeaveNotifyChange:enable
                         failureTitle:@"无法开启退群通知"
                               revert:^{
        WCRRecallNotifySetLeaveSessionEnabled(!enable);
    }];
    os_log_info(WCRLog(), "group leave notify session changed enabled=%{public}d", enable ? 1 : 0);
}

- (void)toggleGroupLeaveNotifySelf:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    WCRRecallNotifySetLeaveSelfEnabled(enable);
    [self applyGroupLeaveNotifyChange:enable
                         failureTitle:@"无法开启退群通知"
                               revert:^{
        WCRRecallNotifySetLeaveSelfEnabled(!enable);
    }];
    os_log_info(WCRLog(), "group leave notify self changed enabled=%{public}d", enable ? 1 : 0);
}

- (void)editGroupLeaveTemplate:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = @"自定义退群格式";
    alert.informativeText =
        @"可用变量：{name} 群昵称（有用户名时可以点开资料页）　{time} 逃离时间（精确到秒）\n"
        @"{wxid} 对方用户名　{group} 群 ID\n"
        @"灰色气泡由微信渲染，无法改字体颜色，可用 emoji 增色。";
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"恢复默认"];
    [alert addButtonWithTitle:@"取消"];

    NSTextView *editor = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 360, 110)];
    editor.string = WCRGroupLeaveStoredTemplate();
    editor.font = [NSFont userFixedPitchFontOfSize:12];
    editor.autoresizingMask = NSViewWidthSizable;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 360, 110)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.documentView = editor;
    alert.accessoryView = scroll;

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        WCRGroupLeaveSetStoredTemplate(editor.string);
        os_log_info(WCRLog(), "group leave template updated (%{public}lu chars)",
                    (unsigned long)editor.string.length);
    } else if (response == NSAlertSecondButtonReturn) {
        WCRGroupLeaveSetStoredTemplate(nil);
    }
}

- (void)refreshState {
    WCRUseIndependentMenuChecks(self.antiRevokeParentItem.menu);
    BOOL enabled = [self antiRevokeEnabled];
    BOOL tipEnabled = [self recallTipEnabled];
    BOOL supportsTip = [self currentProfileSupportsRecallTip];
    NSError *error = nil;
    WCRPatchState state = WCRRecallTipIsInstalled()
        ? WCRPatchStateApplied
        : WCRCurrentProcessPatchState(&error);

    NSString *statusLabel = nil;
    NSString *statusDetail = nil;
    const WCRPatchProfile *statusProfile = WCRCurrentProcessProfile(nil);
    BOOL antiRevokeSite = statusProfile && statusProfile->patchAddress != 0;
    if (statusProfile && !antiRevokeSite) {
        // 构建已登记，但防撤回 cbz 对不上。不要报“字节不匹配”或“重试中”。
        statusLabel = enabled ? @"异常" : @"正常";
        statusDetail = @"防撤回未登记";
    } else switch (state) {
        case WCRPatchStateApplied:
            // 防撤回（静默或带提示）已生效，插件工作正常。
            statusLabel = @"正常";
            statusDetail = @"防撤回已生效";
            break;
        case WCRPatchStatePristine:
            statusLabel = enabled ? @"异常" : @"正常";
            statusDetail = enabled ? @"防撤回未生效，重试中" : @"防撤回已关闭";
            break;
        case WCRPatchStateInvalidBytes:
            statusLabel = @"异常";
            statusDetail = @"补丁点字节不匹配";
            break;
        case WCRPatchStateUnavailable:
        default:
            statusLabel = @"异常";
            statusDetail = error.localizedDescription ?: @"不支持当前微信构建";
            break;
    }
    if (self.versionItem && self.versionTitlePrefix) {
        self.versionItem.title = [self.versionTitlePrefix
            stringByAppendingFormat:@"（%@）", statusLabel];
        self.versionItem.toolTip = statusDetail
            ? [NSString stringWithFormat:@"插件运行情况：%@（%@）", statusLabel, statusDetail]
            : nil;
    }

    // 未登记防撤回时，开着的开关仍要能关掉；关掉之后置灰，避免再点开去写不存在的补丁。
    // 完全没有版本配置时保持置灰。
    BOOL available = !statusProfile ? NO
        : (antiRevokeSite ? (state != WCRPatchStateUnavailable) : enabled);
    self.toggleItem.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.toggleItem.enabled = available;
    self.antiRevokeParentItem.enabled = available;
    self.tipItem.state = tipEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.tipItem.enabled = supportsTip && enabled && available;
    self.contentItem.state = [self recallContentEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    self.contentItem.enabled = tipEnabled && supportsTip && enabled;
    self.templateItem.enabled = tipEnabled && supportsTip && enabled;
    const WCRPatchProfile *notifyProfile = WCRCurrentProcessProfile(nil);
    BOOL notifyAvailable = enabled && WCRRecallNotifySupportsProfile(notifyProfile);
    self.recallNotifyItem.state = WCRRecallNotifyMasterEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    self.recallNotifyItem.enabled = notifyAvailable;
    // 子项在总开关关闭时仍可勾，方便先选好去向。真正发送还要总开关打开。
    self.recallNotifySelfItem.state = WCRRecallNotifySelfEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    self.recallNotifyTargetItem.title = [NSString stringWithFormat:@"接收会话：%@",
        WCRRecallNotifyTargetLabel()];
    NSString *targetSession = WCRRecallNotifyTargetSession();
    self.recallNotifyTargetItem.toolTip = targetSession.length
        ? [NSString stringWithFormat:@"接收会话：%@\n文字直发；其他类型调用微信官方转发。", targetSession]
        : @"接收会话：自己\n文字直发；其他类型调用微信官方转发。";
    self.recallNotifyTargetItem.enabled = YES;
    self.recallNotifySessionItem.state = WCRRecallNotifySessionEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    self.recallNotifyForwardItem.state = WCRRecallNotifyForwardSelfEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    self.recallNotifySelfItem.enabled = notifyAvailable;
    self.recallNotifySessionItem.enabled = notifyAvailable;
    self.recallNotifyForwardItem.enabled = notifyAvailable;
    self.recallNotifyTemplateItem.enabled = notifyAvailable;
    self.recallNotifyContactsItem.state = WCRContactNameNotifyEnabled()
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.recallNotifyContactsItem.enabled = notifyAvailable;
    self.recallNotifyContactsPickerItem.enabled = YES;
    self.voiceForwardItem.state = [self voiceForwardEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    // 语音转发独立于防撤回。只看当前构建有没有登记气泡菜单入口。
    self.voiceForwardItem.enabled = [self currentProfileSupportsVoiceForward];
    BOOL supportsMessageRepeat = [self currentProfileSupportsMessageRepeat];
    self.messageRepeatItem.state = (supportsMessageRepeat && [self messageRepeatEnabled])
        ? NSControlStateValueOn : NSControlStateValueOff;
    // 复读依赖已登记构建的长按菜单收口和动作对象布局；未登记构建置灰。
    self.messageRepeatItem.enabled = supportsMessageRepeat;
    BOOL supportsCommentRepeat = [self currentProfileSupportsCommentRepeat];
    self.commentRepeatItem.state = (supportsCommentRepeat && [self commentRepeatEnabled])
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.commentRepeatItem.enabled = supportsCommentRepeat;
    self.avatarToggleItem.state = [self avatarRoundEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    // 容器行也要反映开关状态（用户期望：开启即打勾）。
    self.avatarParentItem.state = [self avatarRoundEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    self.antiRevokeParentItem.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    // 圆角头像开关始终可点：已登记构建会装形状钩子，未登记构建只保存偏好。
    self.avatarToggleItem.enabled = YES;
    NSInteger avatarRadius = WCRAvatarRoundRadiusPercent();
    for (NSMenuItem *row in self.avatarSubmenu.itemArray) {
        if (row.action != @selector(setAvatarRadiusFromMenu:)) continue;
        row.state = [row.representedObject integerValue] == avatarRadius
            ? NSControlStateValueOn : NSControlStateValueOff;
    }
    self.groupLeaveItem.state = [self groupLeaveEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    self.screenCaptureItem.state = [self screenCaptureBypassEnabled]
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.screenCaptureItem.enabled = YES;
    self.autoUpdateItem.state = [self autoUpdateDisabled]
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.autoUpdateItem.enabled = YES;
    // 退群监控复用消息捕获的收口 Hook，只在登记了收口几何信息的构建上可用
    // （与语音转发同一门控策略：没有登记就置灰，绝不猜测地址）。
    BOOL supportsGroupLeave = [self currentProfileSupportsGroupLeave];
    BOOL groupLeaveOn = [self groupLeaveEnabled];
    // 构建还不支持时，已经打开的开关仍要能关掉。置灰会把点击直接吃掉。
    self.groupLeaveItem.enabled = supportsGroupLeave || groupLeaveOn;
    self.groupLeaveParentItem.state = self.groupLeaveItem.state;
    self.groupLeaveParentItem.enabled = supportsGroupLeave || groupLeaveOn;
    self.groupLeaveTemplateItem.enabled = supportsGroupLeave;
    BOOL groupLeaveNotifyAvailable = [self groupLeaveEnabled] && supportsGroupLeave &&
                                     WCRRecallNotifySupportsProfile(notifyProfile);
    self.groupLeaveNotifySessionItem.state = WCRRecallNotifyLeaveSessionEnabled()
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.groupLeaveNotifySelfItem.state = WCRRecallNotifyLeaveSelfEnabled()
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.groupLeaveNotifySessionItem.enabled = groupLeaveNotifyAvailable;
    self.groupLeaveNotifySelfItem.enabled = groupLeaveNotifyAvailable;
    BOOL supportsOriginalID = [self currentProfileSupportsOriginalID];
    self.originalIDToggleItem.state = (supportsOriginalID && [self originalIDEnabled])
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.originalIDToggleItem.enabled = supportsOriginalID;
    self.originalIDParentItem.state = self.originalIDToggleItem.state;
    self.petSizeItem.enabled = supportsOriginalID;
    if (self.petSizeSlider) {
        self.petSizeSlider.enabled = supportsOriginalID;
        CGFloat size = WCRFloatingIDFontSize();
        if (fabs(self.petSizeSlider.doubleValue - size) >= 0.5) {
            self.petSizeSlider.doubleValue = size;
        }
        NSView *value = [self.petSizeSlider.superview viewWithTag:91];
        if ([value isKindOfClass:[NSTextField class]]) {
            ((NSTextField *)value).stringValue = [NSString stringWithFormat:@"%.0f", size];
        }
    }
    self.petHueItem.enabled = supportsOriginalID;
    if (self.petHueSlider) {
        self.petHueSlider.enabled = supportsOriginalID;
        CGFloat hue = WCRFloatingIDHue();
        if (fabs(self.petHueSlider.doubleValue - hue) >= 0.5) {
            self.petHueSlider.doubleValue = hue;
        }
        self.petHueSwatch.fillColor = WCRFloatingIDHueColor(hue);
    }
    [self refreshPersistentMenuItemViews];
}

- (void)showFailureTitle:(NSString *)title error:(NSError *)error {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = title;
    alert.informativeText = error.localizedDescription ?: @"未知错误";
    [alert runModal];
}

- (void)toggleAntiRevoke:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    NSError *error = nil;
    BOOL ok = NO;
    if (enable) {
        [self setAntiRevokeEnabled:YES];
        ok = [self applyConfiguredMode:&error];
    } else {
        NSError *tipError = nil;
        if (!WCRRecallTipUninstall(&tipError)) {
            error = tipError;
        } else {
            ok = WCRRestoreAntiRevokePatch(&error);
            if (ok) [self setAntiRevokeEnabled:NO];
            // 收口 Hook 是否保留（退群监控/原始 ID 记录可能仍需要）由 sync 裁决。
            [self syncMessageCapture:nil];
        }
    }

    if (!ok) {
        if (enable) [self setAntiRevokeEnabled:NO];
        [self showFailureTitle:enable ? @"无法开启防撤回" : @"无法恢复微信行为" error:error];
        [self refreshState];
        return;
    }

    [self refreshState];
    os_log_info(WCRLog(), "anti-revoke changed enabled=%{public}d", enable ? 1 : 0);
}

- (void)toggleRecallTip:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    [self setRecallTipEnabled:enable];
    NSError *error = nil;
    if ([self antiRevokeEnabled] && ![self applyConfiguredMode:&error]) {
        // 失败时恢复原偏好，避免“开关已关但 Hook 仍在”的不一致。
        [self setRecallTipEnabled:!enable];
        [self syncMessageCapture:nil];
        [self showFailureTitle:@"显示撤回提示切换失败" error:error];
    }
    [self refreshState];
}

- (void)toggleRecallContent:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    // 提示文案在每次撤回到达时实时读取默认值，这里只需保存，无需重装补丁。
    [self setRecallContentEnabled:enable];
    [self refreshState];
}

- (void)editRecallTemplate:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = @"自定义撤回格式";
    alert.informativeText =
        @"可用变量：{name} 撤回人　{time} 撤回时间（秒）　{content} 内容（前 20 字）\n"
        @"{wxid} 对方 wxid　{session} 会话 ID\n"
        @"关闭“显示撤回内容”时，含 {content} 的整行会被去掉。\n"
        @"灰色气泡由微信渲染，无法改字体颜色，可用 emoji 增色。";
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"恢复默认"];
    [alert addButtonWithTitle:@"取消"];

    NSTextView *editor = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 360, 110)];
    editor.string = WCRRecallTipStoredTemplate();
    editor.font = [NSFont userFixedPitchFontOfSize:12];
    editor.autoresizingMask = NSViewWidthSizable;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 360, 110)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.documentView = editor;
    alert.accessoryView = scroll;

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        WCRRecallTipSetStoredTemplate(editor.string);
        os_log_info(WCRLog(), "recall tip template updated (%{public}lu chars)",
                    (unsigned long)editor.string.length);
    } else if (response == NSAlertSecondButtonReturn) {
        WCRRecallTipSetStoredTemplate(nil);
    }
}

- (void)applyRecallNotifyChange:(BOOL)enabling
                   failureTitle:(NSString *)title
                         revert:(void (^)(void))revert {
    if (enabling && [self antiRevokeEnabled] && WCRRecallNotifyWantsCapture()) {
        NSError *error = nil;
        if (!WCRRecallNotifyPrepare(&error)) {
            NSString *message = error.localizedDescription ?: @"";
            if (![message containsString:@"尚未加载"]) {
                if (revert) revert();
                [self syncMessageCapture:nil];
                [self showFailureTitle:title error:error];
                [self refreshState];
                return;
            }
        }
    }
    [self syncMessageCapture:nil];
    [self refreshState];
}

- (void)toggleRecallNotify:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    WCRRecallNotifySetMasterEnabled(enable);
    [self applyRecallNotifyChange:enable failureTitle:@"无法开启撤回消息通知" revert:^{
        WCRRecallNotifySetMasterEnabled(NO);
    }];
    os_log_info(WCRLog(), "recall notify changed enabled=%{public}d", enable ? 1 : 0);
}

- (void)toggleRecallNotifySelf:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    WCRRecallNotifySetSelfEnabled(enable);
    [self applyRecallNotifyChange:enable && WCRRecallNotifyMasterEnabled()
                     failureTitle:@"无法开启撤回消息通知"
                           revert:^{
        WCRRecallNotifySetSelfEnabled(!enable);
    }];
}

- (void)selectRecallNotifyTarget:(NSMenuItem *)sender {
    NSString *value = [sender.representedObject isKindOfClass:[NSString class]]
        ? sender.representedObject : @"";
    if (!WCRRecallNotifySetTargetSession(value.length ? value : nil)) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"接收会话无效";
        alert.informativeText = @"请选择最近会话，或输入 wxid / 数字@chatroom。";
        [alert runModal];
        return;
    }
    WCRConfigStoreBumpRevision();
    [self refreshState];
    os_log_info(WCRLog(), "recall notify target changed (%{public}lu chars)",
                (unsigned long)value.length);
}

- (void)promptRecallNotifyTarget:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = @"选择接收会话";
    alert.informativeText =
        @"输入 wxid 或数字@chatroom。留空恢复“通知给自己”。\n"
        @"文字撤回直接发文字通知；其他支持的类型调用微信官方转发到该会话。";
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 360, 24)];
    field.placeholderString = @"例如 wxid_abcde 或 123456@chatroom";
    field.stringValue = WCRRecallNotifyTargetSession();
    alert.accessoryView = field;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    if (!WCRRecallNotifySetTargetSession(field.stringValue)) {
        NSAlert *errorAlert = [[NSAlert alloc] init];
        errorAlert.alertStyle = NSAlertStyleWarning;
        errorAlert.messageText = @"接收会话无效";
        errorAlert.informativeText = @"需要 5 到 128 位的 wxid，或数字@chatroom。文件传输助手不能作为目标。";
        [errorAlert runModal];
        return;
    }
    WCRConfigStoreBumpRevision();
    [self refreshState];
    os_log_info(WCRLog(), "recall notify target entered manually");
}

- (void)toggleRecallNotifySession:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    WCRRecallNotifySetSessionEnabled(enable);
    [self applyRecallNotifyChange:enable && WCRRecallNotifyMasterEnabled()
                     failureTitle:@"无法开启撤回消息通知"
                           revert:^{
        WCRRecallNotifySetSessionEnabled(!enable);
    }];
}

- (void)toggleNotifyContacts:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    WCRContactNameSetNotifyEnabled(enable);
    WCRConfigStoreBumpRevision();
    [self applyRecallNotifyChange:enable && WCRRecallNotifyMasterEnabled()
                     failureTitle:@"无法开启撤回消息通知"
                           revert:^{
        WCRContactNameSetNotifyEnabled(!enable);
        WCRConfigStoreBumpRevision();
    }];
    os_log_info(WCRLog(), "recall notify contacts changed enabled=%{public}d", enable ? 1 : 0);
}

- (void)presentNotifyContacts:(id)sender {
    (void)sender;
    WCRContactPickerPresentForNotify();
}

- (void)exportConfig:(id)sender {
    (void)sender;
    WCRConfigStorePresentExport(kWCRPluginVersion);
}

- (void)importConfig:(id)sender {
    (void)sender;
    WCRConfigStorePresentImport();
}

- (void)toggleRecallNotifyForward:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    WCRRecallNotifySetForwardSelfEnabled(enable);
    [self applyRecallNotifyChange:enable && WCRRecallNotifyMasterEnabled()
                     failureTitle:@"无法开启撤回消息通知"
                           revert:^{
        WCRRecallNotifySetForwardSelfEnabled(!enable);
    }];
}

- (void)editRecallNotifyTemplate:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = @"自定义通知格式";
    alert.informativeText =
        @"这条通知和灰色撤回提示是两套文案。\n"
        @"可用变量：{name} 撤回人　{time} 撤回时间　{content} 完整内容\n"
        @"{wxid} 对方 wxid　{session} 会话 ID\n"
        @"内容为空时，含 {content} 的整行会被去掉。内容不会截成 20 字。\n"
        @"需要同时打开「显示撤回提示」。文字通知要等开关打开后，有一条文字消息经过收口，才能发出。\n"
        @"“通知给自己”收到文字撤回时直接发这条文字；图片、语音等支持类型改为微信官方转发。";
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"恢复默认"];
    [alert addButtonWithTitle:@"取消"];

    NSTextView *editor = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 360, 110)];
    editor.string = WCRRecallNotifyStoredTemplate();
    editor.font = [NSFont userFixedPitchFontOfSize:12];
    editor.autoresizingMask = NSViewWidthSizable;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 360, 110)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.documentView = editor;
    alert.accessoryView = scroll;

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        WCRRecallNotifySetStoredTemplate(editor.string);
        os_log_info(WCRLog(), "recall notice template updated (%{public}lu chars)",
                    (unsigned long)editor.string.length);
    } else if (response == NSAlertSecondButtonReturn) {
        WCRRecallNotifySetStoredTemplate(nil);
    }
}

- (void)toggleVoiceForward:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    [self setVoiceForwardEnabled:enable];
    NSError *error = nil;
    BOOL ok = [self syncVoiceForward:&error];
    if (!ok) {
        NSString *message = error.localizedDescription ?: @"";
        BOOL pending = [message containsString:@"尚未加载"];
        if (enable && !pending) {
            [self setVoiceForwardEnabled:NO];
            [self syncVoiceForward:nil];
            [self showFailureTitle:@"无法开启语音转发" error:error];
        } else if (!enable) {
            [self setVoiceForwardEnabled:YES];
            [self showFailureTitle:@"无法关闭语音转发" error:error];
        }
    }
    [self refreshState];
    os_log_info(WCRLog(), "voice forward changed enabled=%{public}d", enable ? 1 : 0);
}

- (void)toggleMessageRepeat:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    [self setMessageRepeatEnabled:enable];
    NSError *error = nil;
    BOOL ok = [self syncMessageRepeat:&error];
    if (!ok) {
        NSString *message = error.localizedDescription ?: @"";
        BOOL pending = [message containsString:@"尚未加载"];
        if (enable && !pending) {
            [self setMessageRepeatEnabled:NO];
            [self syncMessageRepeat:nil];
            [self showFailureTitle:@"无法开启消息复读" error:error];
        } else if (!enable) {
            [self setMessageRepeatEnabled:YES];
            [self showFailureTitle:@"无法关闭消息复读" error:error];
        }
    }
    [self syncMessageCapture:nil];
    [self refreshState];
    os_log_info(WCRLog(), "message repeat changed enabled=%{public}d", enable ? 1 : 0);
}

- (void)toggleCommentRepeat:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    [self setCommentRepeatEnabled:enable];
    NSError *error = nil;
    BOOL ok = [self syncCommentRepeat:&error];
    if (!ok) {
        NSString *message = error.localizedDescription ?: @"";
        BOOL pending = [message containsString:@"尚未加载"];
        if (enable && !pending) {
            [self setCommentRepeatEnabled:NO];
            [self syncCommentRepeat:nil];
            [self showFailureTitle:@"无法开启朋友圈评论复读" error:error];
        } else if (!enable) {
            [self setCommentRepeatEnabled:YES];
            [self showFailureTitle:@"无法关闭朋友圈评论复读" error:error];
        }
    }
    [self refreshState];
    os_log_info(WCRLog(), "comment repeat changed enabled=%{public}d", enable ? 1 : 0);
}

- (void)toggleAvatarRound:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    [self setAvatarRoundEnabled:enable];
    NSError *error = nil;
    BOOL ok = [self syncAvatarRound:&error];
    if (enable && !ok) {
        // 模块还没映射时保留偏好，启动重试会再装。其余失败把勾选退回去。
        BOOL pending = [error.localizedDescription containsString:@"尚未加载"];
        if (!pending) {
            [self setAvatarRoundEnabled:NO];
            [self syncAvatarRound:nil];
            [self showFailureTitle:@"无法开启圆角头像" error:error];
        }
    }
    [self refreshState];
    os_log_info(WCRLog(), "avatar round changed enabled=%{public}d", enable ? 1 : 0);
}

/// 写入百分比并刷新钩子缓存。功能已开启但钩子还没装上时补装一次。
- (void)applyAvatarRadiusPercent:(NSInteger)percent {
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    WCRAvatarRoundSetRadiusPercent(percent);
    NSError *error = nil;
    if ([self avatarRoundEnabled] && ![self syncAvatarRound:&error]) {
        NSString *message = error.localizedDescription ?: @"";
        if (![message containsString:@"尚未加载"] &&
            ![message containsString:@"尚未登记"]) {
            [self showFailureTitle:@"圆角大小已保存，形状钩子没装上" error:error];
        }
    } else if (![self avatarRoundEnabled]) {
        WCRAvatarRoundRefreshPrefs();
    }
    [self refreshState];
}

- (void)setAvatarRadiusFromMenu:(NSMenuItem *)sender {
    NSInteger percent = [sender.representedObject integerValue];
    [self applyAvatarRadiusPercent:percent];
    os_log_info(WCRLog(), "avatar radius preset selected (%ld%%)", (long)percent);
}

- (void)showOriginalIDQueryHelp {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = @"已开启原始ID查询功能";
    alert.informativeText =
        @"点击右下小宠物即可复制当前会话原始ID\n"
        @"长按可以拖动，双击重置位置";
    [alert addButtonWithTitle:@"好"];
    [alert runModal];
}

- (void)toggleOriginalID:(NSMenuItem *)sender {
    BOOL enable = !WCRMenuItemChecked(sender);
    [self setOriginalIDEnabled:enable];
    if (enable) [self setFloatingIDEnabled:YES];
    const WCRPatchProfile *idProfile = WCRCurrentProcessProfile(nil);
    BOOL syncCapture = [self antiRevokeEnabled];
    if (idProfile && idProfile->patchAddress == 0) syncCapture = YES;
    if (syncCapture) {
        NSError *error = nil;
        BOOL ok = [self syncMessageCapture:&error];
        if (!ok && enable) {
            [self setOriginalIDEnabled:NO];
            [self syncMessageCapture:nil];
            [self showFailureTitle:@"无法开启原始ID查询" error:error];
        } else if (!ok) {
            os_log_error(WCRLog(), "capture mode uninstall failed: %{public}@",
                         error.localizedDescription ?: @"unknown");
        }
    }
    // 悬浮按钮是原始 ID 的子功能：关掉原始 ID 时一并收起。
    WCRFloatingIDSetEnabled([self originalIDEnabled] && [self floatingIDEnabled] &&
                            [self currentProfileSupportsOriginalID]);
    if (enable && [self originalIDEnabled]) {
        [self showOriginalIDQueryHelp];
    }
    [self refreshState];
}

- (void)toggleFloatingID:(NSMenuItem *)sender {
    BOOL enable = ![self floatingIDEnabled];
    [self setFloatingIDEnabled:enable];
    WCRFloatingIDSetEnabled(enable && [self originalIDEnabled] &&
                            [self currentProfileSupportsOriginalID]);
    [self refreshState];
}

- (void)slideFloatingIDSize:(NSSlider *)slider {
    if (![slider isKindOfClass:[NSSlider class]]) return;
    WCRFloatingIDSetFontSize(slider.doubleValue);
    NSView *value = [slider.superview viewWithTag:91];
    if ([value isKindOfClass:[NSTextField class]]) {
        ((NSTextField *)value).stringValue =
            [NSString stringWithFormat:@"%.0f", slider.doubleValue];
    }
}

- (void)slideFloatingIDHue:(NSSlider *)slider {
    if (![slider isKindOfClass:[NSSlider class]]) return;
    WCRFloatingIDSetHue(slider.doubleValue);
    self.petHueSwatch.fillColor = WCRFloatingIDHueColor(slider.doubleValue);
}

/// 多开副本的 bundle id 与 WCRInstaller 的 WCRMultiInstanceBundleIdentifier 保持一致。
/// 「多开 N 个」= 再拉起 N 个未运行的多开副本；副本不够时引导到管理器创建。
- (void)launchMultiInstances:(NSMenuItem *)sender {
    NSInteger desired = [sender.representedObject integerValue];
    if (desired < 1) desired = 1;

    NSInteger launched = 0;
    NSRunningApplication *firstRunning = nil;
    for (NSUInteger number = 2; number <= 99 && launched < desired; ++number) {
        NSString *bundleID = [NSString stringWithFormat:@"com.tencent.xinWeChat.WCRefineMulti%lu",
                                                        (unsigned long)number];
        NSArray<NSRunningApplication *> *running =
            [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID];
        if (running.count > 0) {
            if (!firstRunning) firstRunning = running.firstObject;
            continue;
        }
        // URLForApplicationWithBundleIdentifier 走 LaunchServices 查询，不依赖
        // 沙盒内文件读权限；安装器装完会用 lsregister 登记副本。
        NSURL *url = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bundleID];
        if (!url) continue;
        NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
        [[NSWorkspace sharedWorkspace] openApplicationAtURL:url
                                              configuration:configuration
                                          completionHandler:^(NSRunningApplication *app, NSError *error) {
            (void)app;
            if (!error) return;
            os_log_error(WCRLog(), "multi-open launch failed: %{public}@",
                         error.localizedDescription ?: @"unknown");
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *alert = [[NSAlert alloc] init];
                alert.alertStyle = NSAlertStyleWarning;
                alert.messageText = @"多开副本启动失败";
                alert.informativeText = error.localizedDescription ?: @"未知错误";
                [alert runModal];
            });
        }];
        launched++;
    }

    if (launched >= desired) {
        os_log_info(WCRLog(), "multi-open launching %ld instance(s)", (long)launched);
        return;
    }
    if (firstRunning) {
        [firstRunning activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = @"多开副本不够";
    alert.informativeText = launched > 0
        ? [NSString stringWithFormat:@"已再开 %ld 个，剩下的多开副本都在运行了。每个多开副本对应一个可同时登录的微信；要开更多，请在 WCRefine for Mac 管理器点「创建多开副本」。", launched]
        : @"能开的多开副本都已在运行。每个多开副本对应一个可同时登录的微信；要开更多，请在 WCRefine for Mac 管理器点「创建多开副本」。";
    NSURL *managerURL = [[NSWorkspace sharedWorkspace]
        URLForApplicationWithBundleIdentifier:@"com.wcrefine.mac.manager"];
    if (managerURL) [alert addButtonWithTitle:@"打开管理器"];
    [alert addButtonWithTitle:@"好"];
    NSInteger response = [alert runModal];
    if (managerURL && response == NSAlertFirstButtonReturn) {
        [[NSWorkspace sharedWorkspace] openApplicationAtURL:managerURL
                                              configuration:[NSWorkspaceOpenConfiguration configuration]
                                          completionHandler:nil];
    }
}

- (void)openUpdateLink:(NSMenuItem *)sender {
    NSURL *url = [sender.representedObject isKindOfClass:[NSURL class]]
        ? sender.representedObject : nil;
    if (!url) return;
    [[NSWorkspace sharedWorkspace] openURL:url];
}

@end

static IMP gOriginalSetMainMenu = NULL;

static void WCRMainMenuSet(id self, SEL _cmd, NSMenu *menu) {
    if (gOriginalSetMainMenu) {
        ((void (*)(id, SEL, NSMenu *))gOriginalSetMainMenu)(self, _cmd, menu);
    }
    WCRRefreshMenu();
}

static void WCRInstallMenuGuard(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method method = class_getInstanceMethod([NSApplication class], @selector(setMainMenu:));
        if (!method) return;
        gOriginalSetMainMenu = method_setImplementation(method, (IMP)WCRMainMenuSet);
    });
}

static void WCRRefreshMenu(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [gMenuController ensureMenu];
    });
}

static BOOL WCRApplyStartupMode(NSError **error) {
    // 收口 Hook（撤回原文捕获/原始 ID 记录/退群监控共用）独立于防撤回开关，
    // 启动时先同步一次。
    [gMenuController syncMessageCapture:nil];
    // 头像圆角开着就安装绘制钩子。失败不清偏好。
    [gMenuController syncAvatarRound:nil];
    // 语音转发开着就安装菜单入口。失败不清偏好。
    [gMenuController syncVoiceForward:nil];
    // 消息复读默认关闭；开启后安装长按菜单 Hook。失败不清偏好。
    [gMenuController syncMessageRepeat:nil];
    // 朋友圈评论复读默认关闭；开启后安装评论菜单 Hook。失败不清偏好。
    [gMenuController syncCommentRepeat:nil];
    // wechat.dylib 可能晚于插件加载；映射后再补开悬浮按钮。
    if ([gMenuController originalIDEnabled] && [gMenuController floatingIDEnabled] &&
        [gMenuController currentProfileSupportsOriginalID]) {
        WCRFloatingIDSetEnabled(YES);
    }
    if (![gMenuController antiRevokeEnabled]) return YES;
    const WCRPatchProfile *startupProfile = WCRCurrentProcessProfile(nil);
    // 补丁点未登记时重试也不会写上。留着偏好，等用户自己关掉。
    if (startupProfile && startupProfile->patchAddress == 0) return YES;
    return [gMenuController applyConfiguredMode:error];
}

static void WCRScheduleStartup(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSNumber *delay in @[@0.2, @0.8, @1.5, @3.0, @6.0, @10.0, @20.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [gMenuController ensureMenu];
                NSError *error = nil;
                if (!WCRApplyStartupMode(&error)) {
                    os_log_error(WCRLog(), "anti-revoke apply failed: %{public}@",
                                 error.localizedDescription ?: @"unknown");
                }
                [gMenuController refreshState];
                WCRScreenCaptureApplyVisibleWindows();
                WCRAutoUpdateApply();
            });
        }
    });
}

static void WCRImageAdded(const struct mach_header *header, intptr_t slide) {
    // wechat.dylib 可能晚于插件加载。映射后再补装依赖它的功能。
    (void)header;
    (void)slide;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error = nil;
        if (!WCRApplyStartupMode(&error)) {
            os_log_debug(WCRLog(), "anti-revoke pending: %{public}@",
                         error.localizedDescription ?: @"unknown");
        }
        [gMenuController refreshState];
    });
}

static BOOL WCRSelfTestApply(NSError **error) {
    if (!WCRApplyAntiRevokePatch(error)) return NO;
    return WCRCurrentProcessPatchState(error) == WCRPatchStateApplied;
}

static void *WCRSelfTestMain(void *) {
    @autoreleasepool {
        NSError *error = nil;
        for (int i = 0; i < 3000; ++i) {
            if (WCRSelfTestApply(&error)) {
                fprintf(stderr, "WCRefine self-test: patch applied\n");
                _exit(0);
            }
            NSString *message = error.localizedDescription ?: @"";
            if ([message containsString:@"补丁点字节不匹配"] ||
                [message containsString:@"入口字节不匹配"]) {
                fprintf(stderr, "WCRefine self-test: %s\n", message.UTF8String);
                _exit(3);
            }
            if ([message containsString:@"暂不支持当前微信构建"]) {
                fprintf(stderr, "WCRefine self-test: %s\n", message.UTF8String);
                _exit(2);
            }
            usleep(10 * 1000);
            error = nil;
        }
        NSString *message = error.localizedDescription ?: @"self-test timed out";
        fprintf(stderr, "WCRefine self-test: %s\n", message.UTF8String);
        _exit(2);
    }
}

static BOOL WCRIsSelfTest(void) {
    const char *raw = getenv("WCR_MAC_SELFTEST");
    return raw && strcmp(raw, "1") == 0;
}

__attribute__((constructor)) static void WCRefineMacInitialize(void) {
    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        BOOL selfTest = WCRIsSelfTest();
        if (!WCRHostBundleIdentifierAllowed(bundle.bundleIdentifier, selfTest)) return;

        if (selfTest) {
            pthread_t thread;
            if (pthread_create(&thread, nullptr, WCRSelfTestMain, nullptr) == 0) {
                pthread_detach(thread);
            }
            return;
        }

        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            gMenuController = [[WCRMenuController alloc] init];
            WCRInstallMenuGuard();
            // 防截图钩子要早于 wechat.dylib 建窗。默认开：普通窗口的
            // NSWindowSharingNone 改成 ReadOnly，截图遮罩（状态栏层级）不动。
            WCRScreenCaptureInstall();
            WCRScreenCaptureSetBypassEnabled([gMenuController screenCaptureBypassEnabled]);
            // 更新钩子要早于 Sparkle 的 startUpdater。默认开：
            // 后台检查、自动下载和菜单里的「检查更新」都不执行。
            // 不拦安全模式，也不拦 crashpad 的崩溃日志。
            WCRAutoUpdateInstall();
            WCRAutoUpdateSetEnabled([gMenuController autoUpdateDisabled]);
            NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
            NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];
            [center addObserverForName:WCRNotifyContactsDidChangeNotification
                                object:nil
                                 queue:mainQueue
                            usingBlock:^(NSNotification *note) {
                (void)note;
                BOOL enabling = WCRRecallNotifyMasterEnabled() && WCRContactNameNotifyEnabled();
                [gMenuController applyRecallNotifyChange:enabling
                                           failureTitle:@"无法开启撤回消息通知"
                                                 revert:nil];
            }];
            [center addObserverForName:WCRConfigDidImportNotification
                                object:nil
                                 queue:mainQueue
                            usingBlock:^(NSNotification *note) {
                (void)note;
                WCRContactNameReloadStyle();
                WCRAutoUpdateSetEnabled([gMenuController autoUpdateDisabled]);
                WCRScreenCaptureSetBypassEnabled([gMenuController screenCaptureBypassEnabled]);
                NSError *error = nil;
                if (!WCRApplyStartupMode(&error)) {
                    os_log_error(WCRLog(), "config import reapply failed: %{public}@",
                                 error.localizedDescription ?: @"unknown");
                }
                if ([gMenuController originalIDEnabled] && [gMenuController floatingIDEnabled] &&
                    [gMenuController currentProfileSupportsOriginalID]) {
                    WCRFloatingIDSetEnabled(YES);
                } else {
                    WCRFloatingIDSetEnabled(NO);
                }
                [gMenuController refreshState];
            }];
            // 原始 ID 记录与退群监控都挂在消息捕获点上（分发器转发）；
            // hook 未安装时观察者不会被调用。
            WCRMessageCaptureSetObjectObserver(WCRMessageCaptureDispatch);
            if ([gMenuController originalIDEnabled] && [gMenuController floatingIDEnabled] &&
                [gMenuController currentProfileSupportsOriginalID]) {
                WCRFloatingIDSetEnabled(YES);
            }
            // wechat.dylib 可能晚于插件。映射后再补装依赖它的功能。
            _dyld_register_func_for_add_image(WCRImageAdded);
            WCRScheduleStartup();
            os_log_info(WCRLog(), "WCRefine Mac loaded for WeChat %{public}@",
                        [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?");
        });
    }
}
