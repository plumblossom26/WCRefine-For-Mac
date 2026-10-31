#import "WCRScreenCapture.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <os/log.h>

#include <atomic>

static os_log_t WCRScreenLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.wcrefine.mac", "screen");
    });
    return log;
}

static IMP gOriginalSetSharingType = NULL;
static std::atomic<bool> gBypassEnabled{false};

/// 截图遮罩先 setLevel:NSStatusWindowLevel 再 setSharingType:None。
/// 主窗口停在普通层级，防截图策略只改 sharingType。
static BOOL WCRWindowIsCaptureOverlay(NSWindow *window) {
    return window.level >= NSStatusWindowLevel;
}

static void WCRWindowSetSharingType(id self, SEL _cmd, NSWindowSharingType type) {
    if (gBypassEnabled.load(std::memory_order_relaxed) &&
        type == NSWindowSharingNone &&
        [self isKindOfClass:[NSWindow class]] &&
        !WCRWindowIsCaptureOverlay((NSWindow *)self)) {
        type = NSWindowSharingReadOnly;
    }
    if (gOriginalSetSharingType) {
        ((void (*)(id, SEL, NSWindowSharingType))gOriginalSetSharingType)(self, _cmd, type);
    }
}

void WCRScreenCaptureApplyVisibleWindows(void) {
    if (!gBypassEnabled.load(std::memory_order_relaxed)) return;
    for (NSWindow *window in [NSApp windows]) {
        if (WCRWindowIsCaptureOverlay(window)) continue;
        if (window.sharingType != NSWindowSharingNone) continue;
        window.sharingType = NSWindowSharingReadOnly;
    }
}

static void WCRScreenCaptureNoteWindow(NSNotification *note) {
    if (!gBypassEnabled.load(std::memory_order_relaxed)) return;
    NSWindow *window = note.object;
    if (![window isKindOfClass:[NSWindow class]]) return;
    if (WCRWindowIsCaptureOverlay(window)) return;
    if ((window.occlusionState & NSWindowOcclusionStateVisible) == 0) return;
    if (window.sharingType != NSWindowSharingNone) return;
    window.sharingType = NSWindowSharingReadOnly;
}

void WCRScreenCaptureInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method method = class_getInstanceMethod([NSWindow class], @selector(setSharingType:));
        if (!method) {
            os_log_error(WCRScreenLog(), "NSWindow setSharingType: missing");
            return;
        }
        gOriginalSetSharingType = method_setImplementation(method, (IMP)WCRWindowSetSharingType);
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowDidChangeOcclusionStateNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
                        WCRScreenCaptureNoteWindow(note);
                    }];
        os_log_info(WCRScreenLog(), "screen-capture bypass hook installed");
    });
}

void WCRScreenCaptureSetBypassEnabled(BOOL enabled) {
    gBypassEnabled.store(enabled, std::memory_order_relaxed);
    if (!enabled) {
        os_log_info(WCRScreenLog(), "screen-capture bypass enabled=0");
        return;
    }
    if ([NSThread isMainThread]) {
        WCRScreenCaptureApplyVisibleWindows();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            WCRScreenCaptureApplyVisibleWindows();
        });
    }
    os_log_info(WCRScreenLog(), "screen-capture bypass enabled=1");
}

BOOL WCRScreenCaptureIsBypassEnabled(void) {
    return gBypassEnabled.load(std::memory_order_relaxed);
}
