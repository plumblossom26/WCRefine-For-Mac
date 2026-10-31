#import "WCRAutoUpdate.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

#include <atomic>

static os_log_t WCRUpdateLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.wcrefine.mac", "update");
    });
    return log;
}

static NSString *const kSparkleAutomaticChecks = @"SUEnableAutomaticChecks";
static NSString *const kSparkleAutomaticDownload = @"SUAutomaticallyUpdate";
static NSString *const kSparkleBackupPresent = @"WCRefineMacSparkleBackupPresent";
static NSString *const kSparkleChecksBackup = @"WCRefineMacSparkleChecksBackup";
static NSString *const kSparkleDownloadBackup = @"WCRefineMacSparkleDownloadBackup";

static std::atomic<bool> gBlocked{false};
static bool gHooksReady = false;
static __weak id gUpdater = nil;

static IMP gSPUBackground = NULL;
static IMP gSUBackground = NULL;
static IMP gSPUTimer = NULL;
static IMP gSPUChecks = NULL;
static IMP gSUChecks = NULL;
static IMP gSPUSetChecks = NULL;
static IMP gSUSetChecks = NULL;
static IMP gSPUDownloads = NULL;
static IMP gSUDownloads = NULL;
static IMP gSPUSetDownloads = NULL;
static IMP gSUSetDownloads = NULL;
static IMP gSPUStart = NULL;
static IMP gSUInstall = NULL;
static IMP gControllerStart = NULL;
static IMP gSPUManual = NULL;
static IMP gSUManual = NULL;
static IMP gControllerManual = NULL;
static IMP gSPUManualArg = NULL;
static IMP gSUManualArg = NULL;
static IMP gControllerManualArg = NULL;

static BOOL WCRBlocked(void) {
    return gBlocked.load(std::memory_order_relaxed);
}

static void WCRRemember(id object) {
    if (!object) return;
    Class updaterClass = NSClassFromString(@"SPUUpdater");
    if (updaterClass && [object isKindOfClass:updaterClass]) {
        gUpdater = object;
    }
}

static BOOL WCRIsLegacyUpdater(id object) {
    Class legacy = NSClassFromString(@"SUUpdater");
    return legacy && [object isKindOfClass:legacy];
}

static void WCRHook(Class cls, SEL sel, IMP replacement, IMP *slot) {
    if (!cls || !sel || !slot || *slot) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        os_log_error(WCRUpdateLog(), "missing %{public}s %{public}s",
                     class_getName(cls), sel_getName(sel));
        return;
    }
    *slot = method_setImplementation(method, replacement);
}

/// SUUpdater 和控制器不一定有 checkForUpdates。缺了就跳过，不打错误日志。
static void WCRHookOptional(Class cls, SEL sel, IMP replacement, IMP *slot) {
    if (!cls || !sel || !slot || *slot) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    *slot = method_setImplementation(method, replacement);
}

static BOOL WCRIsController(id object) {
    Class controller = NSClassFromString(@"SPUStandardUpdaterController");
    return controller && [object isKindOfClass:controller];
}

static void WCRManual(id self, SEL _cmd) {
    WCRRemember(self);
    if (WCRBlocked()) {
        os_log_info(WCRUpdateLog(), "manual update check blocked");
        return;
    }
    IMP original = WCRIsLegacyUpdater(self) ? gSUManual
        : (WCRIsController(self) ? gControllerManual : gSPUManual);
    if (original) ((void (*)(id, SEL))original)(self, _cmd);
}

static void WCRManualArg(id self, SEL _cmd, id sender) {
    WCRRemember(self);
    if (WCRBlocked()) {
        os_log_info(WCRUpdateLog(), "manual update check blocked");
        return;
    }
    IMP original = WCRIsLegacyUpdater(self) ? gSUManualArg
        : (WCRIsController(self) ? gControllerManualArg : gSPUManualArg);
    if (original) ((void (*)(id, SEL, id))original)(self, _cmd, sender);
}

static void WCRBackground(id self, SEL _cmd) {
    WCRRemember(self);
    if (WCRBlocked()) return;
    IMP original = WCRIsLegacyUpdater(self) ? gSUBackground : gSPUBackground;
    if (original) ((void (*)(id, SEL))original)(self, _cmd);
}

static void WCRTimer(id self, SEL _cmd) {
    WCRRemember(self);
    if (WCRBlocked()) return;
    if (gSPUTimer) ((void (*)(id, SEL))gSPUTimer)(self, _cmd);
}

static BOOL WCRChecks(id self, SEL _cmd) {
    WCRRemember(self);
    if (WCRBlocked()) return NO;
    IMP original = WCRIsLegacyUpdater(self) ? gSUChecks : gSPUChecks;
    if (!original) return NO;
    return ((BOOL (*)(id, SEL))original)(self, _cmd);
}

static void WCRSetChecks(id self, SEL _cmd, BOOL value) {
    WCRRemember(self);
    if (WCRBlocked()) value = NO;
    IMP original = WCRIsLegacyUpdater(self) ? gSUSetChecks : gSPUSetChecks;
    if (original) ((void (*)(id, SEL, BOOL))original)(self, _cmd, value);
}

static BOOL WCRDownloads(id self, SEL _cmd) {
    WCRRemember(self);
    if (WCRBlocked()) return NO;
    IMP original = WCRIsLegacyUpdater(self) ? gSUDownloads : gSPUDownloads;
    if (!original) return NO;
    return ((BOOL (*)(id, SEL))original)(self, _cmd);
}

static void WCRSetDownloads(id self, SEL _cmd, BOOL value) {
    WCRRemember(self);
    if (WCRBlocked()) value = NO;
    IMP original = WCRIsLegacyUpdater(self) ? gSUSetDownloads : gSPUSetDownloads;
    if (original) ((void (*)(id, SEL, BOOL))original)(self, _cmd, value);
}

static void WCRSendVoid(id target, SEL sel) {
    if (!target || !sel || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL))objc_msgSend)(target, sel);
}

static void WCRSendBool(id target, SEL sel, BOOL value) {
    if (!target || !sel || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(target, sel, value);
}

static id WCRSendId(id target, SEL sel) {
    if (!target || !sel || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static void WCRCancelCycle(id updater) {
    WCRSendVoid(updater, @selector(cancelNextUpdateCycle));
}

static void WCRPushOff(id updater) {
    if (!updater) return;
    WCRRemember(updater);
    WCRSendBool(updater, @selector(setAutomaticallyChecksForUpdates:), NO);
    WCRSendBool(updater, @selector(setAutomaticallyDownloadsUpdates:), NO);
    WCRCancelCycle(updater);
}

static BOOL WCRStart(id self, SEL _cmd, NSError **error) {
    WCRRemember(self);
    if (WCRBlocked()) WCRPushOff(self);
    BOOL ok = YES;
    if (gSPUStart) ok = ((BOOL (*)(id, SEL, NSError **))gSPUStart)(self, _cmd, error);
    if (WCRBlocked()) WCRPushOff(self);
    return ok;
}

static void WCRInstallIfAvailable(id self, SEL _cmd) {
    WCRRemember(self);
    if (WCRBlocked()) return;
    if (gSUInstall) ((void (*)(id, SEL))gSUInstall)(self, _cmd);
}

static void WCRControllerStart(id self, SEL _cmd) {
    id updater = WCRSendId(self, @selector(updater));
    if (WCRBlocked()) WCRPushOff(updater);
    if (gControllerStart) ((void (*)(id, SEL))gControllerStart)(self, _cmd);
    updater = WCRSendId(self, @selector(updater));
    WCRRemember(updater);
    if (WCRBlocked()) WCRPushOff(updater);
}

static void WCRBackupSparkleDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kSparkleBackupPresent]) return;
    id checks = [defaults objectForKey:kSparkleAutomaticChecks];
    id downloads = [defaults objectForKey:kSparkleAutomaticDownload];
    [defaults setBool:YES forKey:kSparkleBackupPresent];
    if (checks) [defaults setObject:checks forKey:kSparkleChecksBackup];
    else [defaults removeObjectForKey:kSparkleChecksBackup];
    if (downloads) [defaults setObject:downloads forKey:kSparkleDownloadBackup];
    else [defaults removeObjectForKey:kSparkleDownloadBackup];
}

static void WCRRestoreSparkleDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:kSparkleBackupPresent]) return;
    id checks = [defaults objectForKey:kSparkleChecksBackup];
    id downloads = [defaults objectForKey:kSparkleDownloadBackup];
    if (checks) [defaults setObject:checks forKey:kSparkleAutomaticChecks];
    else [defaults removeObjectForKey:kSparkleAutomaticChecks];
    if (downloads) [defaults setObject:downloads forKey:kSparkleAutomaticDownload];
    else [defaults removeObjectForKey:kSparkleAutomaticDownload];
    [defaults removeObjectForKey:kSparkleChecksBackup];
    [defaults removeObjectForKey:kSparkleDownloadBackup];
    [defaults removeObjectForKey:kSparkleBackupPresent];
}

static void WCRWriteBlockedDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:NO forKey:kSparkleAutomaticChecks];
    [defaults setBool:NO forKey:kSparkleAutomaticDownload];
}

static void WCRInstallHooksNow(void) {
    if (gHooksReady) return;
    Class updater = NSClassFromString(@"SPUUpdater");
    if (!updater) return;

    SEL background = @selector(checkForUpdatesInBackground);
    SEL timer = @selector(updaterTimerDidFire);
    SEL checks = @selector(automaticallyChecksForUpdates);
    SEL setChecks = @selector(setAutomaticallyChecksForUpdates:);
    SEL downloads = @selector(automaticallyDownloadsUpdates);
    SEL setDownloads = @selector(setAutomaticallyDownloadsUpdates:);
    SEL start = @selector(startUpdater:);
    SEL install = @selector(installUpdatesIfAvailable);
    SEL controllerStart = @selector(startUpdater);

    WCRHook(updater, background, (IMP)WCRBackground, &gSPUBackground);
    WCRHook(updater, timer, (IMP)WCRTimer, &gSPUTimer);
    WCRHook(updater, checks, (IMP)WCRChecks, &gSPUChecks);
    WCRHook(updater, setChecks, (IMP)WCRSetChecks, &gSPUSetChecks);
    WCRHook(updater, downloads, (IMP)WCRDownloads, &gSPUDownloads);
    WCRHook(updater, setDownloads, (IMP)WCRSetDownloads, &gSPUSetDownloads);
    WCRHook(updater, start, (IMP)WCRStart, &gSPUStart);

    Class legacy = NSClassFromString(@"SUUpdater");
    WCRHook(legacy, background, (IMP)WCRBackground, &gSUBackground);
    WCRHook(legacy, checks, (IMP)WCRChecks, &gSUChecks);
    WCRHook(legacy, setChecks, (IMP)WCRSetChecks, &gSUSetChecks);
    WCRHook(legacy, downloads, (IMP)WCRDownloads, &gSUDownloads);
    WCRHook(legacy, setDownloads, (IMP)WCRSetDownloads, &gSUSetDownloads);
    WCRHook(legacy, install, (IMP)WCRInstallIfAvailable, &gSUInstall);

    Class controller = NSClassFromString(@"SPUStandardUpdaterController");
    WCRHook(controller, controllerStart, (IMP)WCRControllerStart, &gControllerStart);

    SEL manual = @selector(checkForUpdates);
    SEL manualArg = @selector(checkForUpdates:);
    WCRHookOptional(updater, manual, (IMP)WCRManual, &gSPUManual);
    WCRHookOptional(updater, manualArg, (IMP)WCRManualArg, &gSPUManualArg);
    WCRHookOptional(legacy, manual, (IMP)WCRManual, &gSUManual);
    WCRHookOptional(legacy, manualArg, (IMP)WCRManualArg, &gSUManualArg);
    WCRHookOptional(controller, manual, (IMP)WCRManual, &gControllerManual);
    WCRHookOptional(controller, manualArg, (IMP)WCRManualArg, &gControllerManualArg);

    gHooksReady = YES;
    os_log_info(WCRUpdateLog(), "sparkle auto-update hooks installed");
}

static void WCROnImage(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    Dl_info info;
    if (dladdr(header, &info) && info.dli_fname && !strstr(info.dli_fname, "Sparkle")) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        WCRInstallHooksNow();
        if (WCRBlocked()) WCRAutoUpdateApply();
    });
}

void WCRAutoUpdateInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WCRInstallHooksNow();
        _dyld_register_func_for_add_image(WCROnImage);
    });
}

static void WCRResumeUpdater(void) {
    WCRSendVoid(gUpdater, @selector(resetUpdateCycle));
}

void WCRAutoUpdateSetEnabled(BOOL enabled) {
    gBlocked.store(enabled, std::memory_order_relaxed);
    if (enabled) {
        WCRBackupSparkleDefaults();
        WCRWriteBlockedDefaults();
        WCRPushOff(gUpdater);
        os_log_info(WCRUpdateLog(), "auto-update blocked=1");
        return;
    }
    WCRRestoreSparkleDefaults();
    WCRResumeUpdater();
    os_log_info(WCRUpdateLog(), "auto-update blocked=0");
}

BOOL WCRAutoUpdateIsEnabled(void) {
    return WCRBlocked();
}

void WCRAutoUpdateApply(void) {
    WCRInstallHooksNow();
    if (!WCRBlocked()) return;
    WCRBackupSparkleDefaults();
    WCRWriteBlockedDefaults();
    WCRPushOff(gUpdater);
}
