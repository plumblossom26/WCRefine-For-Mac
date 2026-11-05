#import "WCRFloatingID.h"

#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <os/log.h>

#import "WCROriginalID.h"

#include <dlfcn.h>
#include <math.h>

static NSWindow *WCRLargestChatWindow(void);

// 小宠物默认停在聊天窗口右下角，避开顶栏和输入框。拖动后记住相对
// 窗口左上角的位置，双击清除，回到右下角。
// 面积小于下面阈值的窗口（登录页等）不算聊天窗口，此时浮窗隐藏。
static NSString *const kWCRFloatingOffsetRightKey = @"WCRefineMacFloatingIDOffsetRightV2";
static NSString *const kWCRFloatingOffsetLeftKey = @"WCRefineMacFloatingIDOffsetLeftV3";
static NSString *const kWCRFloatingOffsetTopKey = @"WCRefineMacFloatingIDOffsetTopV3";
static NSString *const kWCRFloatingBackgroundKey = @"WCRefineMacFloatingIDBackground";
static NSString *const kWCRFloatingFontSizeKey = @"WCRefineMacFloatingIDFontSize";
static NSString *const kWCRFloatingHueKey = @"WCRefineMacFloatingIDHue";
static NSString *const kWCRPetBoundsMessageName = @"wcrPetBounds";
static const CGFloat kWCRDefaultFontSize = 13.0;
// 身体中心 #1D89FF 的色相。滑杆停在这里时页面不改色，避免把原来的蓝洗掉。
static const CGFloat kWCRDefaultPetHue = 211.33;
static const CGFloat kWCRDefaultOffsetTop = 12.0;
static const CGFloat kWCRPetInsetRight = 18.0;
static const CGFloat kWCRPetInsetBottom = 96.0;
static const CGFloat kWCRMinChatWindowWidth = 600.0;
static const CGFloat kWCRMinChatWindowHeight = 500.0;

static BOOL WCRHasCustomOffset(void) {
    return [[NSUserDefaults standardUserDefaults] objectForKey:kWCRFloatingOffsetLeftKey] != nil;
}

static CGFloat WCROffsetLeft(void) {
    NSNumber *stored = [[NSUserDefaults standardUserDefaults]
        objectForKey:kWCRFloatingOffsetLeftKey];
    CGFloat value = stored ? stored.doubleValue : 0;
    return MAX(0.0, MIN(value, 4000.0));
}

static CGFloat WCROffsetTop(void) {
    NSNumber *stored = [[NSUserDefaults standardUserDefaults]
        objectForKey:kWCRFloatingOffsetTopKey];
    CGFloat value = stored ? stored.doubleValue : kWCRDefaultOffsetTop;
    return MAX(4.0, MIN(value, 2000.0));
}

static void WCRSaveOffsetLeft(CGFloat value) {
    [[NSUserDefaults standardUserDefaults] setDouble:value
                                              forKey:kWCRFloatingOffsetLeftKey];
}

static void WCRSaveOffsetTop(CGFloat value) {
    [[NSUserDefaults standardUserDefaults] setDouble:value
                                              forKey:kWCRFloatingOffsetTopKey];
}

// 没存过就是无背景。用户关掉玻璃之后，这里必须读到 NO，不能再默认打开。
static BOOL WCRFloatingBackgroundOn(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kWCRFloatingBackgroundKey];
    if (![stored isKindOfClass:[NSNumber class]]) return NO;
    return [(NSNumber *)stored boolValue];
}

static CGFloat WCRClampFontSize(CGFloat value) {
    if (value < 9.0) return 9.0;
    if (value > 28.0) return 28.0;
    return value;
}

static CGFloat WCRFloatingFontSizeValue(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kWCRFloatingFontSizeKey];
    if (![stored isKindOfClass:[NSNumber class]]) return kWCRDefaultFontSize;
    return WCRClampFontSize([(NSNumber *)stored doubleValue]);
}

static CGFloat WCRClampHue(CGFloat value) {
    if (value < 0.0) return 0.0;
    if (value > 360.0) return 360.0;
    return value;
}

static CGFloat WCRFloatingHueValue(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kWCRFloatingHueKey];
    if (![stored isKindOfClass:[NSNumber class]]) return kWCRDefaultPetHue;
    return WCRClampHue([(NSNumber *)stored doubleValue]);
}

static CGFloat WCRHueChannel(CGFloat p, CGFloat q, CGFloat t) {
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

// 滑杆 9 到 28 线性对应边长 76 到 148。乘 6.4 再夹紧时，23 以上都是最大，
// 拖到右边宠物不会再变。
static CGFloat WCRPetSide(void) {
    CGFloat font = WCRFloatingFontSizeValue();
    CGFloat t = (font - 9.0) / 19.0;
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    return round(76.0 + t * 72.0);
}

static os_log_t WCRFloatingLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.wcrefine.mac", "plugin");
    });
    return log;
}

// 页面和 pet.js 跟 dylib 放在同一个 Resources 目录下的 kimi-pet/。
static NSURL *WCRPetDirectory(void) {
    NSFileManager *files = [NSFileManager defaultManager];
    Dl_info info;
    if (dladdr((const void *)WCRFloatingIDSetEnabled, &info) && info.dli_fname) {
        NSString *dylib = [NSString stringWithUTF8String:info.dli_fname];
        NSString *pet = [[dylib stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"kimi-pet"];
        NSString *page = [pet stringByAppendingPathComponent:@"index.html"];
        NSString *script = [pet stringByAppendingPathComponent:@"pet.js"];
        if ([files fileExistsAtPath:page] && [files fileExistsAtPath:script]) {
            return [NSURL fileURLWithPath:pet isDirectory:YES];
        }
    }
    NSString *bundled = [[NSBundle mainBundle].resourcePath
        stringByAppendingPathComponent:@"kimi-pet"];
    NSString *page = [bundled stringByAppendingPathComponent:@"index.html"];
    NSString *script = [bundled stringByAppendingPathComponent:@"pet.js"];
    if ([files fileExistsAtPath:page] && [files fileExistsAtPath:script]) {
        return [NSURL fileURLWithPath:bundled isDirectory:YES];
    }
    return nil;
}

#pragma mark - 按钮视图

/// 右下角只放宠物。点一下复制当前会话的原始 ID，不把 ID 画在宠物上。
@interface WCRFloatingIDBadgeView : NSView <WKNavigationDelegate>
@property(nonatomic, copy) NSString *hudText;
@property(nonatomic, copy) NSString *currentID;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) NSTextField *hudLabel;
@property(nonatomic, strong) NSView *glassView;
@property(nonatomic, assign) CGPoint dragStartMouse;
@property(nonatomic, assign) NSPoint dragStartOrigin;
@property(nonatomic, assign) BOOL dragged;
@property(nonatomic, assign) BOOL toldDrag;
@property(nonatomic, assign) BOOL pressing;
@property(nonatomic, assign) NSRect bodyBounds;
@property(nonatomic, assign) BOOL bodyBoundsValid;
- (void)copySessionID:(NSString *)sessionID;
- (void)installChrome;
- (void)loadPetIfNeeded;
- (void)evalPet:(NSString *)script;
- (void)updateBodyBounds:(NSDictionary *)body;
- (BOOL)containsPetBodyAtPoint:(NSPoint)point;
@end

@interface WCRFloatingIDBoundsHandler : NSObject <WKScriptMessageHandler>
@property(nonatomic, weak) WCRFloatingIDBadgeView *badge;
@end

@implementation WCRFloatingIDBoundsHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)userContentController;
    if (![message.name isEqualToString:kWCRPetBoundsMessageName]) return;
    NSDictionary *body = [message.body isKindOfClass:[NSDictionary class]] ? message.body : nil;
    if (body) [self.badge updateBodyBounds:body];
}

@end

// -1 还没装过，0 纯宠物，1 玻璃底。用来避免每两秒拆一次视图。
static int gChromeMode = -1;
static BOOL gPetReady = NO;

static NSPanel *gPanel = nil;
static WCRFloatingIDBadgeView *gBadge = nil;
static NSWindow *gAttachedWindow = nil;
static id gMoveObserver = nil;
static id gResizeObserver = nil;
static id gMainObserver = nil;
static id gCloseObserver = nil;
static id gFrontObserver = nil;
static NSTimer *gPositionTimer = nil;
static NSTimer *gCursorTimer = nil;
static CGPoint gLastCursor = {NAN, NAN};
// 菜单追踪里抽默认模式会重入定时器。挡住再抽一次。
static BOOL gHuePumping = NO;
static CFAbsoluteTime gHuePumpedAt = 0;
static void WCRFloatingApplyFront(void);
static void WCRFloatingReposition(void);
static void WCRPushCursor(void);
static void WCRUpdateMousePassthrough(void);

@implementation WCRFloatingIDBadgeView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    WKWebpagePreferences *page = [[WKWebpagePreferences alloc] init];
    page.allowsContentJavaScript = YES;
    config.defaultWebpagePreferences = page;
    // 页面脚本跑起来之前就把色相写上，第一帧就是存好的颜色。
    WKUserContentController *scripts = [[WKUserContentController alloc] init];
    NSString *boot = [NSString stringWithFormat:@"window.__wcrHue=%.2f;", WCRFloatingHueValue()];
    WKUserScript *hueBoot = [[WKUserScript alloc] initWithSource:boot
                                                   injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                forMainFrameOnly:YES];
    [scripts addUserScript:hueBoot];
    WCRFloatingIDBoundsHandler *boundsHandler = [[WCRFloatingIDBoundsHandler alloc] init];
    boundsHandler.badge = self;
    [scripts addScriptMessageHandler:boundsHandler name:kWCRPetBoundsMessageName];
    config.userContentController = scripts;
    // 同目录的 pet.js 要能被 file URL 页面读到。
    @try {
        [config.preferences setValue:@YES forKey:@"allowFileAccessFromFileURLs"];
    } @catch (NSException *exception) {
        (void)exception;
    }

    WKWebView *web = [[WKWebView alloc] initWithFrame:frame configuration:config];
    web.navigationDelegate = self;
    web.wantsLayer = YES;
    web.layer.opaque = NO;
    web.layer.backgroundColor = NSColor.clearColor.CGColor;
    web.underPageBackgroundColor = NSColor.clearColor;
    @try {
        [web setValue:@NO forKey:@"drawsBackground"];
    } @catch (NSException *exception) {
        (void)exception;
    }
    web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.webView = web;
    [self addSubview:web];

    NSTextField *hud = [NSTextField labelWithString:@""];
    hud.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]
        ?: [NSFont systemFontOfSize:12];
    hud.textColor = [NSColor labelColor] ?: [NSColor blackColor];
    hud.alignment = NSTextAlignmentCenter;
    hud.lineBreakMode = NSLineBreakByClipping;
    hud.maximumNumberOfLines = 1;
    hud.drawsBackground = YES;
    hud.backgroundColor = [NSColor colorWithCalibratedWhite:1 alpha:0.88];
    hud.bezeled = NO;
    hud.editable = NO;
    hud.selectable = NO;
    hud.hidden = YES;
    hud.wantsLayer = YES;
    hud.layer.cornerRadius = 8;
    hud.layer.masksToBounds = YES;
    self.hudLabel = hud;
    [self addSubview:hud];

    gChromeMode = -1;
    [self installChrome];
    return self;
}

- (void)loadPetIfNeeded {
    if (self.webView.URL) return;
    NSURL *directory = WCRPetDirectory();
    if (!directory) {
        os_log_error(WCRFloatingLog(), "floating pet resources missing");
        return;
    }
    NSURL *page = [directory URLByAppendingPathComponent:@"index.html"];
    [self.webView loadFileURL:page allowingReadAccessToURL:directory];
}

- (void)evalPet:(NSString *)script {
    if (!gPetReady || script.length == 0 || !self.webView) return;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        (void)result;
        if (error) {
            os_log_error(WCRFloatingLog(), "pet js: %{public}@",
                         error.localizedDescription ?: @"unknown");
        }
    }];
}

- (void)updateBodyBounds:(NSDictionary *)body {
    NSNumber *x = body[@"x"];
    NSNumber *y = body[@"y"];
    NSNumber *width = body[@"width"];
    NSNumber *height = body[@"height"];
    if (![x isKindOfClass:[NSNumber class]] ||
        ![y isKindOfClass:[NSNumber class]] ||
        ![width isKindOfClass:[NSNumber class]] ||
        ![height isKindOfClass:[NSNumber class]]) {
        return;
    }
    CGFloat xValue = x.doubleValue;
    CGFloat yValue = y.doubleValue;
    CGFloat widthValue = width.doubleValue;
    CGFloat heightValue = height.doubleValue;
    if (!isfinite(xValue) || !isfinite(yValue) ||
        !isfinite(widthValue) || !isfinite(heightValue) ||
        widthValue <= 0 || heightValue <= 0) {
        return;
    }
    self.bodyBounds = NSMakeRect(xValue, yValue, widthValue, heightValue);
    self.bodyBoundsValid = YES;
    WCRUpdateMousePassthrough();
}

- (BOOL)containsPetBodyAtPoint:(NSPoint)point {
    if (!self.webView) return NO;
    NSPoint webPoint = [self.webView convertPoint:point fromView:self];
    if (!self.webView.isFlipped) {
        webPoint.y = NSHeight(self.webView.bounds) - webPoint.y;
    }

    NSRect body = self.bodyBounds;
    if (!self.bodyBoundsValid || !isfinite(body.origin.x) || !isfinite(body.origin.y) ||
        !isfinite(body.size.width) || !isfinite(body.size.height) ||
        body.size.width <= 0 || body.size.height <= 0) {
        // 页面边界消息还没到时先用居中的保守椭圆，不能退回整块方形窗口。
        CGFloat side = MIN(NSWidth(self.bounds), NSHeight(self.bounds));
        CGFloat diameter = side * 0.46;
        body = NSMakeRect((NSWidth(self.bounds) - diameter) / 2.0,
                          (NSHeight(self.bounds) - diameter) / 2.0,
                          diameter,
                          diameter);
    }
    CGFloat inset = MIN(2.0, MIN(body.size.width, body.size.height) * 0.04);
    body = NSInsetRect(body, inset, inset);
    if (body.size.width <= 0 || body.size.height <= 0) return NO;

    CGFloat nx = (webPoint.x - NSMidX(body)) / (body.size.width / 2.0);
    CGFloat ny = (webPoint.y - NSMidY(body)) / (body.size.height / 2.0);
    return nx * nx + ny * ny <= 1.0;
}

- (void)installChrome {
    if (self.glassView) {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
        if (@available(macOS 26.0, *)) {
            if ([self.glassView isKindOfClass:[NSGlassEffectView class]]) {
                ((NSGlassEffectView *)self.glassView).contentView = nil;
            }
        }
#endif
        [self.glassView removeFromSuperview];
        self.glassView = nil;
    }
    // 玻璃只垫在宠物后面。关掉时页面本身是透明的，只剩果冻。
    if (!WCRFloatingBackgroundOn()) {
        gChromeMode = 0;
        if (self.hudLabel) [self addSubview:self.hudLabel];
        return;
    }

    NSView *glass = nil;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *effect = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
        effect.cornerRadius = 10.0;
        effect.style = NSGlassEffectViewStyleRegular;
        glass = effect;
    }
#endif
    if (!glass) {
        NSVisualEffectView *effect = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
        effect.material = NSVisualEffectMaterialPopover;
        effect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        effect.state = NSVisualEffectStateActive;
        effect.wantsLayer = YES;
        effect.layer.masksToBounds = YES;
        glass = effect;
    }
    if (self.webView) {
        [self addSubview:glass positioned:NSWindowBelow relativeTo:self.webView];
    } else {
        [self addSubview:glass];
    }
    self.glassView = glass;
    if (self.hudLabel) [self addSubview:self.hudLabel];
    gChromeMode = 1;
}

- (NSView *)hitTest:(NSPoint)point {
    // 只有果冻身体接收点击；透明边交给下面的微信窗口。
    if (![self containsPetBodyAtPoint:point]) return nil;
    return self;
}

- (BOOL)isOpaque { return NO; }

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
}

- (void)mouseDown:(NSEvent *)event {
    self.pressing = YES;
    self.dragStartMouse = NSEvent.mouseLocation;
    self.dragStartOrigin = self.window.frame.origin;
    self.dragged = NO;
    self.toldDrag = NO;
    if (event.clickCount >= 2) {
        if (self.toldDrag) {
            [self evalPet:@"window.wcrSetDragging(false,false)"];
        }
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults removeObjectForKey:kWCRFloatingOffsetLeftKey];
        [defaults removeObjectForKey:kWCRFloatingOffsetTopKey];
        [defaults removeObjectForKey:kWCRFloatingOffsetRightKey];
        [self showHUD:@"位置已重置"];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:NSWindowDidMoveNotification object:nil];
    }
}

- (void)mouseDragged:(NSEvent *)event {
    (void)event;
    CGPoint mouse = NSEvent.mouseLocation;
    if (hypot(mouse.x - self.dragStartMouse.x, mouse.y - self.dragStartMouse.y) < 3) {
        return;
    }
    if (!self.toldDrag) {
        self.toldDrag = YES;
        [self evalPet:@"window.wcrSetDragging(true,false)"];
    }
    self.dragged = YES;
    NSPoint origin = self.dragStartOrigin;
    NSPoint delta = NSMakePoint(mouse.x - self.dragStartMouse.x,
                                mouse.y - self.dragStartMouse.y);
    [self.window setFrameOrigin:NSMakePoint(origin.x + delta.x, origin.y + delta.y)];
}

- (void)mouseUp:(NSEvent *)event {
    self.pressing = NO;
    if (self.dragged) {
        [self evalPet:@"window.wcrSetDragging(false,false)"];
        NSWindow *target = WCRLargestChatWindow();
        NSWindow *selfWindow = self.window;
        if (target && selfWindow) {
            NSRect targetFrame = target.frame;
            NSRect myFrame = selfWindow.frame;
            WCRSaveOffsetLeft(myFrame.origin.x - targetFrame.origin.x);
            WCRSaveOffsetTop(NSMaxY(targetFrame) - NSMaxY(myFrame));
        }
        self.dragged = NO;
        self.toldDrag = NO;
        WCRUpdateMousePassthrough();
        return;
    }
    if (event.clickCount >= 2) {
        WCRUpdateMousePassthrough();
        return;
    }
    [self evalPet:@"window.wcrNoteInteraction()"];
    [self copySessionID:self.currentID];
    WCRUpdateMousePassthrough();
}

- (void)copySessionID:(NSString *)sessionID {
    if (sessionID.length == 0) {
        [self showHUD:@"无记录"];
        return;
    }
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:sessionID forType:NSPasteboardTypeString];
    [self showHUD:@"已复制"];
}

- (void)showHUD:(NSString *)text {
    self.hudText = text;
    WCRFloatingApplyFront();
    [NSTimer scheduledTimerWithTimeInterval:1.5
                                    repeats:NO
                                      block:^(NSTimer *timer) {
        (void)timer;
        if (self.hudText != text) return;
        self.hudText = nil;
        WCRFloatingApplyFront();
    }];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)navigation;
    [webView evaluateJavaScript:@"window.__wcrReady === true ? 'ok' : (window.__wcrError || 'not-ready')"
              completionHandler:^(id result, NSError *error) {
        if (webView != gBadge.webView) return;
        NSString *text = [result isKindOfClass:[NSString class]] ? result : @"";
        if ([text isEqualToString:@"ok"]) {
            gPetReady = YES;
            os_log_info(WCRFloatingLog(), "floating pet mounted");
            [self evalPet:@"window.wcrResize()"];
            [self evalPet:[NSString stringWithFormat:@"window.wcrSetHue(%.2f)",
                                                     WCRFloatingHueValue()]];
            return;
        }
        gPetReady = NO;
        NSString *why = text.length ? text : (error.localizedDescription ?: @"unknown");
        os_log_error(WCRFloatingLog(), "floating pet not mounted: %{public}@", why);
    }];
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
    (void)webView;
    (void)navigation;
    gPetReady = NO;
    os_log_error(WCRFloatingLog(), "floating pet navigation failed: %{public}@",
                 error.localizedDescription ?: @"unknown");
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation
            withError:(NSError *)error {
    (void)webView;
    (void)navigation;
    gPetReady = NO;
    os_log_error(WCRFloatingLog(), "floating pet navigation failed: %{public}@",
                 error.localizedDescription ?: @"unknown");
}

@end

#pragma mark - 面板控制

static NSWindow *WCRLargestChatWindow(void) {
    NSWindow *target = nil;
    CGFloat bestArea = 0;
    for (NSWindow *window in NSApp.windows) {
        if (window == gPanel || !window.visible || window.isMiniaturized) continue;
        NSRect frame = window.frame;
        if (frame.size.width < kWCRMinChatWindowWidth ||
            frame.size.height < kWCRMinChatWindowHeight) {
            continue;
        }
        CGFloat area = frame.size.width * frame.size.height;
        if (area > bestArea) {
            bestArea = area;
            target = window;
        }
    }
    return target;
}

static void WCRFloatingReposition(void) {
    if (!gPanel) return;

    NSWindow *target = WCRLargestChatWindow();
    if (!target) {
        if (gAttachedWindow) {
            [gAttachedWindow removeChildWindow:gPanel];
            gAttachedWindow = nil;
        }
        [gPanel orderOut:nil];
        return;
    }

    if (gAttachedWindow != target) {
        [gAttachedWindow removeChildWindow:gPanel];
        [target addChildWindow:gPanel ordered:NSWindowAbove];
        gAttachedWindow = target;
    }

    NSRect frame = target.frame;
    CGFloat chipW = gPanel.frame.size.width;
    CGFloat chipH = gPanel.frame.size.height;
    if (chipW < 8) chipW = 8;
    if (chipH < 8) chipH = 8;
    NSPoint origin;
    if (WCRHasCustomOffset()) {
        origin = NSMakePoint(frame.origin.x + WCROffsetLeft(),
                             NSMaxY(frame) - WCROffsetTop() - chipH);
    } else {
        origin = NSMakePoint(NSMaxX(frame) - kWCRPetInsetRight - chipW,
                             frame.origin.y + kWCRPetInsetBottom);
    }
    CGFloat minX = frame.origin.x + 8;
    CGFloat maxX = NSMaxX(frame) - 8 - chipW;
    if (maxX < minX) maxX = minX;
    if (origin.x < minX) origin.x = minX;
    if (origin.x > maxX) origin.x = maxX;
    CGFloat minY = frame.origin.y + 8;
    CGFloat maxY = NSMaxY(frame) - 8 - chipH;
    if (origin.y < minY) origin.y = minY;
    if (origin.y > maxY) origin.y = maxY;
    if (!gBadge.dragged) {
        [gPanel setFrameOrigin:origin];
    }
    if (!gPanel.visible) [gPanel orderFront:nil];
}

// 把屏幕上的鼠标换成宠物画布的坐标。画布原点在左上，眼睛用这个方向看。
static void WCRUpdateMousePassthrough(void) {
    if (!gPanel || !gBadge) return;
    BOOL interactive = gBadge.pressing || gBadge.dragged;
    if (!interactive) {
        NSPoint screenPoint = NSEvent.mouseLocation;
        NSPoint windowPoint = [gPanel convertPointFromScreen:screenPoint];
        NSPoint badgePoint = [gBadge convertPoint:windowPoint fromView:nil];
        interactive = [gBadge containsPetBodyAtPoint:badgePoint];
    }
    BOOL shouldIgnore = !interactive;
    if (gPanel.ignoresMouseEvents != shouldIgnore) {
        gPanel.ignoresMouseEvents = shouldIgnore;
    }
}

static void WCRPushCursor(void) {
    if (!gPanel || !gBadge) return;
    WCRUpdateMousePassthrough();
    if (!gPetReady || !gPanel.visible || !gBadge.webView) return;
    NSPoint screen = NSEvent.mouseLocation;
    if (hypot(screen.x - gLastCursor.x, screen.y - gLastCursor.y) < 0.5) return;
    gLastCursor = screen;
    // mouseLocation 是屏幕坐标。网页要的是画布左上角那套坐标。
    NSPoint windowPoint = [gPanel convertPointFromScreen:screen];
    NSPoint local = [gBadge.webView convertPoint:windowPoint fromView:nil];
    CGFloat height = NSHeight(gBadge.webView.bounds);
    CGFloat x = local.x;
    // WKWebView 是翻转视图，local.y 已经是网页那套「上边为 0」。
    // 再减一次，眼睛上下就会看反。
    CGFloat y = gBadge.webView.isFlipped ? local.y : height - local.y;
    BOOL inside = NSPointInRect(local, gBadge.webView.bounds);
    NSString *script = nil;
    if (gBadge.dragged) {
        script = [NSString stringWithFormat:@"window.wcrSetCursor(%.2f,%.2f,%@,%.2f)",
                  x, y, inside ? @"true" : @"false", x];
    } else {
        script = [NSString stringWithFormat:@"window.wcrSetCursor(%.2f,%.2f,%@)",
                  x, y, inside ? @"true" : @"false"];
    }
    // 跟手的调用很密，失败不写日志，免得把控制台刷满。
    [gBadge.webView evaluateJavaScript:script completionHandler:nil];
}

static void WCRFloatingEnsureChrome(void) {
    if (!gBadge) return;
    int want = WCRFloatingBackgroundOn() ? 1 : 0;
    if (gChromeMode != want) [gBadge installChrome];
}

static void WCRFloatingLayoutPet(void) {
    if (!gBadge) return;
    CGFloat side = NSWidth(gBadge.bounds);
    CGFloat height = NSHeight(gBadge.bounds);
    if (gBadge.webView) {
        gBadge.webView.frame = gBadge.bounds;
    }
    NSView *glass = gBadge.glassView;
    if (glass) {
        glass.frame = gBadge.bounds;
        CGFloat radius = MIN(side, height) / 2.0;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
        if (@available(macOS 26.0, *)) {
            if ([glass isKindOfClass:[NSGlassEffectView class]]) {
                ((NSGlassEffectView *)glass).cornerRadius = radius;
            }
        }
#endif
        glass.layer.cornerRadius = radius;
    }
    NSTextField *hud = gBadge.hudLabel;
    if (!hud) return;
    if (gBadge.hudText.length == 0) {
        hud.hidden = YES;
        hud.stringValue = @"";
        return;
    }
    hud.hidden = NO;
    hud.stringValue = gBadge.hudText;
    CGFloat hudW = MIN(MAX(36.0, side - 10.0), 64.0);
    CGFloat hudH = 18.0;
    hud.frame = NSMakeRect((side - hudW) / 2.0, 6.0, hudW, hudH);
}

static void WCRFloatingApplyFront(void) {
    if (!gPanel || !gBadge) return;
    NSString *front = WCROriginalIDFrontValue() ?: @"";
    gBadge.currentID = front;

    WCRFloatingEnsureChrome();
    CGFloat side = WCRPetSide();
    NSRect frame = gPanel.frame;
    BOOL resized = fabs(frame.size.width - side) > 0.5 || fabs(frame.size.height - side) > 0.5;
    if (resized) {
        if (gBadge) gBadge.bodyBoundsValid = NO;
        // 菜单和弹窗都在追踪循环里，主队列要等松手才跑。这里先改窗口，再同步通知网页。
        if (gBadge.dragged) {
            [gPanel setFrame:NSMakeRect(NSMaxX(frame) - side,
                                        NSMaxY(frame) - side,
                                        side,
                                        side)
                     display:NO];
        } else {
            [gPanel setFrame:NSMakeRect(frame.origin.x, frame.origin.y, side, side)
                     display:NO];
        }
    }
    WCRFloatingLayoutPet();
    if (resized) WCRUpdateMousePassthrough();
    if (resized && gPetReady) {
        NSString *script = [NSString stringWithFormat:@"window.wcrResize(%.0f,%.0f)", side, side];
        [gBadge evalPet:script];
    }
    if (!gBadge.dragged) WCRFloatingReposition();
    if (resized) [gPanel displayIfNeeded];
}

BOOL WCRFloatingIDIsEnabled(void) {
    return gPanel != nil;
}

BOOL WCRFloatingIDSetEnabled(BOOL enabled) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            WCRFloatingIDSetEnabled(enabled);
        });
        return YES;
    }
    if (enabled && gPanel) return YES;
    if (!enabled) {
        if (gAttachedWindow) {
            [gAttachedWindow removeChildWindow:gPanel];
            gAttachedWindow = nil;
        }
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        if (gMoveObserver) [center removeObserver:gMoveObserver];
        if (gResizeObserver) [center removeObserver:gResizeObserver];
        if (gMainObserver) [center removeObserver:gMainObserver];
        if (gCloseObserver) [center removeObserver:gCloseObserver];
        if (gFrontObserver) [center removeObserver:gFrontObserver];
        gMoveObserver = gResizeObserver = gMainObserver = gCloseObserver = gFrontObserver = nil;
        [gPositionTimer invalidate];
        gPositionTimer = nil;
        [gCursorTimer invalidate];
        gCursorTimer = nil;
        gPetReady = NO;
        gLastCursor = NSMakePoint(NAN, NAN);
        gBadge.webView.navigationDelegate = nil;
        [gBadge.webView stopLoading];
        [gPanel orderOut:nil];
        gPanel = nil;
        gBadge = nil;
        gChromeMode = -1;
        return YES;
    }

    CGFloat side = WCRPetSide();
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, side, side)
                  styleMask:NSWindowStyleMaskBorderless |
                            NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.level = NSFloatingWindowLevel + 1;
    panel.opaque = NO;
    panel.backgroundColor = [NSColor clearColor];
    panel.hasShadow = NO;
    // 面板默认让鼠标穿透；只有指针进入宠物身体时才临时接收点击。
    panel.ignoresMouseEvents = YES;
    panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.releasedWhenClosed = NO;
    panel.acceptsMouseMovedEvents = YES;

    WCRFloatingIDBadgeView *badge =
        [[WCRFloatingIDBadgeView alloc] initWithFrame:NSMakeRect(0, 0, side, side)];
    panel.contentView = badge;

    gPanel = panel;
    gBadge = badge;
    [badge loadPetIfNeeded];
    WCRFloatingApplyFront();

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSOperationQueue *queue = [NSOperationQueue mainQueue];
    void (^repositionBlock)(NSNotification *) = ^(NSNotification *note) {
        (void)note;
        WCRFloatingReposition();
    };
    gMoveObserver = [center addObserverForName:NSWindowDidMoveNotification
                                        object:nil
                                         queue:queue
                                    usingBlock:repositionBlock];
    gResizeObserver = [center addObserverForName:NSWindowDidEndLiveResizeNotification
                                          object:nil
                                           queue:queue
                                      usingBlock:^(NSNotification *note) {
        (void)note;
        WCRFloatingApplyFront();
    }];
    gMainObserver = [center addObserverForName:NSWindowDidBecomeMainNotification
                                        object:nil
                                         queue:queue
                                    usingBlock:repositionBlock];
    gCloseObserver = [center addObserverForName:NSWindowWillCloseNotification
                                         object:nil
                                          queue:queue
                                     usingBlock:repositionBlock];
    gFrontObserver = [center addObserverForName:WCROriginalIDFrontDidChangeNotification
                                         object:nil
                                          queue:queue
                                     usingBlock:^(NSNotification *note) {
        (void)note;
        WCRFloatingApplyFront();
    }];
    gPositionTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                     repeats:YES
                                                       block:^(NSTimer *timer) {
        (void)timer;
        WCRFloatingApplyFront();
    }];
    // 穿透区域按指针实时切换；60Hz 可避免从消息提示移入宠物后首击落空。
    gCursorTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                                   repeats:YES
                                                     block:^(NSTimer *timer) {
        (void)timer;
        WCRPushCursor();
    }];
    return YES;
}

BOOL WCRFloatingIDBackgroundEnabled(void) {
    return WCRFloatingBackgroundOn();
}

static void WCRFloatingApplyAppearance(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            WCRFloatingApplyFront();
        });
        return;
    }
    WCRFloatingApplyFront();
}

void WCRFloatingIDSetBackgroundEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kWCRFloatingBackgroundKey];
    os_log_info(WCRFloatingLog(), "floating id background=%d", enabled ? 1 : 0);
    WCRFloatingApplyAppearance();
}

CGFloat WCRFloatingIDFontSize(void) {
    return WCRFloatingFontSizeValue();
}

void WCRFloatingIDSetFontSize(CGFloat size) {
    size = WCRClampFontSize(size);
    CGFloat previous = WCRFloatingFontSizeValue();
    BOOL valueChanged = fabs(previous - size) >= 0.01;
    if (valueChanged) {
        [[NSUserDefaults standardUserDefaults] setDouble:size forKey:kWCRFloatingFontSizeKey];
        if (fabs(round(previous) - round(size)) >= 1.0) {
            os_log_info(WCRFloatingLog(), "floating id size=%.0f", round(size));
        }
    }
    if (!gPanel) return;
    if (fabs(NSWidth(gPanel.frame) - WCRPetSide()) <= 0.5) return;
    WCRFloatingApplyAppearance();
}

CGFloat WCRFloatingIDHue(void) {
    return WCRFloatingHueValue();
}

NSColor *WCRFloatingIDHueColor(CGFloat hue) {
    hue = WCRClampHue(hue);
    if (fabs(hue - kWCRDefaultPetHue) < 0.75) {
        return [NSColor colorWithSRGBRed:(0x1D / 255.0)
                                   green:(0x89 / 255.0)
                                    blue:(0xFF / 255.0)
                                   alpha:1.0];
    }
    // 跟页面同一套：色相换成滑杆的值，饱和度和明度留在身体中心 #1D89FF。
    CGFloat h = hue / 360.0;
    CGFloat s = 1.0;
    CGFloat l = 142.0 / 255.0;
    CGFloat q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
    CGFloat p = 2.0 * l - q;
    return [NSColor colorWithSRGBRed:WCRHueChannel(p, q, h + 1.0 / 3.0)
                               green:WCRHueChannel(p, q, h)
                                blue:WCRHueChannel(p, q, h - 1.0 / 3.0)
                               alpha:1.0];
}

void WCRFloatingIDSetHue(CGFloat hue) {
    hue = WCRClampHue(hue);
    CGFloat previous = WCRFloatingHueValue();
    if (fabs(previous - hue) >= 0.01) {
        [[NSUserDefaults standardUserDefaults] setDouble:hue forKey:kWCRFloatingHueKey];
        if (fabs(round(previous) - round(hue)) >= 1.0) {
            os_log_info(WCRFloatingLog(), "floating id hue=%.0f", round(hue));
        }
    }
    if (!gBadge || !gPetReady) return;
    // 菜单追踪不提交网页的新帧，所以只改色相的话要等松手才看得到。
    // 脚本每次都交出去。追踪模式里再抽一小段默认模式，把刚画好的帧贴上来。
    NSString *script = [NSString stringWithFormat:@"window.wcrSetHue(%.2f)", hue];
    [gBadge evalPet:script];
    if (gHuePumping || ![NSThread isMainThread]) return;
    CFStringRef mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain());
    BOOL tracking = mode && CFStringCompare(mode, kCFRunLoopDefaultMode, 0) != kCFCompareEqualTo;
    if (mode) CFRelease(mode);
    if (!tracking) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gHuePumpedAt > 0 && now - gHuePumpedAt < 0.04) return;
    gHuePumpedAt = now;
    gHuePumping = YES;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
    gHuePumping = NO;
    if (gPanel) [gPanel displayIfNeeded];
}
