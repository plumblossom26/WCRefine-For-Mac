#import "WCRAvatarRound.h"

#import "WCRCodePatch.h"
#import "WCRPatchProfiles.h"

#import <Foundation/Foundation.h>

#import <atomic>
#import <cmath>
#import <cstring>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <sys/mman.h>
#import <libkern/OSCacheControl.h>

NSString *const kWCRAvatarRoundRadiusDefaultsKey = @"WCRefineMacAvatarRadiusPercent";
static NSString *const kWCRAvatarRoundEnabledKey = @"WCRefineMacAvatarRoundEnabled";

// 头像绘制钩子（270135，wechat.dylib+0x1f3c2cc）。
// 这个函数才裁位图：它先调形状绘制（vtable+480 = 0x1f3d3d0），返回后才读
// widget+468 的形状模式和 +472/+476 的半径。形状函数在 widget+523 为 0 时
// 直接返回；钩子若包在形状函数里，恢复模式的时机早于这里读半径，画面不变。
// 所以钩子包住整个绘制函数，画完再恢复。禁用时不碰任何字段。
// 模式 2 = 纯圆（短边的一半，不读半径）。模式 0 = 跳过圆角裁剪。
// 100% 强制模式 2。0–99 用模式 1，半径 = min(宽,高)/2 * 百分比/100（逻辑像素）。
// 宽高来自 widget+40 指向的几何：+20 左上、+28 右下，单位与半径字段相同。
// 绘制函数是图片控件共用的。预览图、通话画面、链接图标和普通图片也进这里。
// 头像只认下面三张虚表。其余控件原样绘制。
// 未设置时头像百分比是 100。

extern "C" {

static std::atomic_bool gInstalled(false);
static std::atomic_bool gEnabled(false);
static std::atomic_int gPercent(100);
static uintptr_t gWechatSlide = 0;
static uint8_t gSavedEntry[16];
static uint8_t *gEntry = nullptr;
// 裸桩用 adrp 按外部符号取跳板；隐藏可见性，不进 dylib 导出表。
__attribute__((visibility("hidden"))) void *gWCRShapeTrampoline = nullptr;

// 绘制在主线程串行；单槽记录被临时改写的形状模式即可。
static std::atomic<void *> gSavedWidget(nullptr);
static std::atomic<uint32_t> gSavedMode(0);
static std::atomic<uint32_t> gSavedRadiusX(0);
static std::atomic<uint32_t> gSavedRadiusY(0);

static uint32_t WCRFloatBits(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float WCRBitsFloat(uint32_t bits) {
    float value = 0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

constexpr uint32_t kModeCircle = 2;
constexpr uint32_t kModeRounded = 1;
constexpr size_t kModeOffset = 468;
constexpr size_t kRadiusXOffset = 472;
constexpr size_t kRadiusYOffset = 476;
constexpr size_t kGeomPointerOffset = 40;
constexpr size_t kGeomTopLeftOffset = 20;
constexpr size_t kGeomBottomRightOffset = 28;
// 主虚表，imagebase 0。槽 0 是各自的 metaObject，绘制槽在 +456。
// 0x9d60e00 mmui::XAvatarImage
// 0x9b80c80 mmui::ContactHeadView（父类 XAvatarImage，会话列表头像）
// 0x9bde890 mmui::SNSAvatarHeadView（父类 ContactHeadView，朋友圈头像）
constexpr uint64_t kAvatarVtableOffsets[] = {
    0x9d60e00,
    0x9b80c80,
    0x9bde890,
};

static bool WCRWidgetVtableIn(void *widget, const uint64_t *table, size_t count) {
    uintptr_t vtable = 0;
    memcpy(&vtable, widget, sizeof(vtable));
    uintptr_t slide = gWechatSlide;
    if (!slide || vtable < slide) return false;
    uint64_t offset = (uint64_t)(vtable - slide);
    for (size_t i = 0; i < count; ++i) {
        if (offset == table[i]) return true;
    }
    return false;
}

static bool WCRWidgetIsAvatar(void *widget) {
    return WCRWidgetVtableIn(widget, kAvatarVtableOffsets,
                             sizeof(kAvatarVtableOffsets) / sizeof(kAvatarVtableOffsets[0]));
}

static NSError *AvatarRoundError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMac.AvatarRound"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"圆角头像错误"}];
}

}  // extern "C"

static NSInteger WCRStoredPercent(NSString *key, NSInteger fallback) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (!stored) return fallback;
    NSInteger percent = [stored integerValue];
    if (percent < 0 || percent > 100) return fallback;
    return percent;
}

static void WCRStorePercent(NSString *key, NSInteger percent) {
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    [[NSUserDefaults standardUserDefaults] setInteger:percent forKey:key];
}

NSInteger WCRAvatarRoundRadiusPercent(void) {
    return WCRStoredPercent(kWCRAvatarRoundRadiusDefaultsKey, 100);
}

void WCRAvatarRoundSetRadiusPercent(NSInteger percent) {
    WCRStorePercent(kWCRAvatarRoundRadiusDefaultsKey, percent);
}

void WCRAvatarRoundRefreshPrefs(void) {
    gPercent.store((int)WCRStoredPercent(kWCRAvatarRoundRadiusDefaultsKey, 100), std::memory_order_relaxed);
    id enabled = [[NSUserDefaults standardUserDefaults] objectForKey:kWCRAvatarRoundEnabledKey];
    gEnabled.store(enabled ? [enabled boolValue] : NO, std::memory_order_relaxed);
}

BOOL WCRAvatarRoundSupportsProfile(const WCRPatchProfile *profile) {
    return profile && profile->avatarShapeAddress != 0;
}

static bool WCRAvatarLogicalSize(void *widget, float *width, float *height) {
    void *geom = nullptr;
    memcpy(&geom, (char *)widget + kGeomPointerOffset, sizeof(geom));
    if (!geom) return false;
    int32_t topLeft[2] = {0, 0};
    int32_t bottomRight[2] = {0, 0};
    memcpy(topLeft, (char *)geom + kGeomTopLeftOffset, sizeof(topLeft));
    memcpy(bottomRight, (char *)geom + kGeomBottomRightOffset, sizeof(bottomRight));
    float logicalWidth = (float)(bottomRight[0] - topLeft[0] + 1);
    float logicalHeight = (float)(bottomRight[1] - topLeft[1] + 1);
    if (!(logicalWidth > 1.0f && logicalHeight > 1.0f &&
          logicalWidth < 20000.0f && logicalHeight < 20000.0f)) {
        return false;
    }
    *width = logicalWidth;
    *height = logicalHeight;
    return true;
}

extern "C" {
/// 按百分比改写形状模式。几何读失败时不保存，绘制后的恢复就是空操作。
static void WCRShapeApplyPercent(void *widget, int percent) {
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    float radius = 0;
    if (percent < 100 && percent > 0) {
        float width = 0;
        float height = 0;
        if (!WCRAvatarLogicalSize(widget, &width, &height)) return;
        // 与手机版 WCRAvatarCornerRadiusFromPercent 相同：100 = 短边的一半。
        radius = fminf(width, height) * 0.5f * (percent / 100.0f);
    }
    char *base = (char *)widget;
    gSavedWidget.store(widget);
    gSavedMode.store(*(uint32_t *)(base + kModeOffset));
    gSavedRadiusX.store(WCRFloatBits(*(float *)(base + kRadiusXOffset)));
    gSavedRadiusY.store(WCRFloatBits(*(float *)(base + kRadiusYOffset)));
    if (percent >= 100) {
        // 模式 2 是绘制函数自己的纯圆，不读半径字段。
        *(uint32_t *)(base + kModeOffset) = kModeCircle;
    } else {
        // 模式 0 会跳过圆角裁剪，部分圆角必须走非 0 非 2 的半径路径。
        *(uint32_t *)(base + kModeOffset) = kModeRounded;
        *(float *)(base + kRadiusXOffset) = radius;
        *(float *)(base + kRadiusYOffset) = radius;
    }
}

/// 绘制前：只改头像。其余控件原样绘制。
/// used：唯一调用点在裸桩汇编里，编译器看不到。
__attribute__((used, visibility("hidden")))
void WCRAvatarRoundPreDraw(void *widget) {
    if (!widget) return;
    if (!WCRWidgetIsAvatar(widget)) return;
    if (!gEnabled.load(std::memory_order_relaxed)) return;
    WCRShapeApplyPercent(widget, gPercent.load(std::memory_order_relaxed));
}

/// 绘制后：恢复被临时改写的形状模式。
__attribute__((used, visibility("hidden")))
void WCRAvatarRoundPostDraw(void *widget) {
    void *saved = gSavedWidget.load();
    if (saved != widget || !widget) return;
    char *base = (char *)widget;
    *(uint32_t *)(base + kModeOffset) = gSavedMode.load();
    *(float *)(base + kRadiusXOffset) = WCRBitsFloat(gSavedRadiusX.load());
    *(float *)(base + kRadiusYOffset) = WCRBitsFloat(gSavedRadiusY.load());
    gSavedWidget.store(nullptr);
}

/// 裸桩：改写参数 → 调原绘制 → 恢复形状模式。
__attribute__((naked)) static void WCRShapeDrawStub(void) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-128]!\n"
        "stp x0, x1, [sp, #16]\n"
        "stp x2, x3, [sp, #32]\n"
        "stp x4, x5, [sp, #48]\n"
        "stp x6, x7, [sp, #64]\n"
        "str x8, [sp, #80]\n"
        "bl _WCRAvatarRoundPreDraw\n"
        "ldp x0, x1, [sp, #16]\n"
        "ldp x2, x3, [sp, #32]\n"
        "ldp x4, x5, [sp, #48]\n"
        "ldp x6, x7, [sp, #64]\n"
        "ldr x8, [sp, #80]\n"
        "adrp x16, _gWCRShapeTrampoline@PAGE\n"
        "ldr x16, [x16, _gWCRShapeTrampoline@PAGEOFF]\n"
        "blr x16\n"
        "str x0, [sp, #88]\n"
        "ldr x0, [sp, #16]\n"
        "bl _WCRAvatarRoundPostDraw\n"
        "ldr x0, [sp, #88]\n"
        "ldp x29, x30, [sp], #128\n"
        "ret\n"
    );
}

}  // extern "C"

BOOL WCRAvatarRoundInstall(NSError **error) {
    if (gInstalled.load()) return YES;
    WCRAvatarRoundRefreshPrefs();

    NSError *profileError = nil;
    const WCRPatchProfile *profile = WCRCurrentProcessProfile(&profileError);
    if (!WCRAvatarRoundSupportsProfile(profile)) {
        if (error) {
            *error = AvatarRoundError(
                @"当前微信构建尚未登记头像绘制函数，功能保持仅偏好模式");
        }
        return NO;
    }

    uintptr_t slide = 0;
    bool found = false;
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/wechat.dylib")) {
            slide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
            found = true;
            break;
        }
    }
    // 先记下基址，绘制线程进钩子时才能用虚表偏移认出头像。
    if (found) gWechatSlide = slide;
    if (!found) {
        if (error) *error = AvatarRoundError(@"wechat.dylib 尚未加载");
        return NO;
    }

    uint8_t *entry = reinterpret_cast<uint8_t *>(slide + profile->avatarShapeAddress);
    uint8_t current[16];
    memcpy(current, entry, sizeof(current));
    uint8_t expected[16];
    for (int k = 0; k < 4; ++k)
        memcpy(expected + 4 * k, &profile->avatarShapePrologue[k], 4);
    if (memcmp(current, expected, sizeof(current)) != 0) {
        NSMutableString *actual = [NSMutableString string];
        for (int k = 0; k < 16; ++k) [actual appendFormat:@"%02x", current[k]];
        if (error) *error = AvatarRoundError([NSString stringWithFormat:
            @"头像绘制点字节不匹配（当前 %@）", actual]);
        return NO;
    }

    const size_t kTrampolineBytes = 32;
    void *trampoline = mmap(nullptr, kTrampolineBytes, PROT_READ | PROT_WRITE,
                            MAP_ANON | MAP_PRIVATE, -1, 0);
    if (trampoline == MAP_FAILED) {
        if (error) *error = AvatarRoundError(@"无法分配头像跳板");
        return NO;
    }
    uint8_t *tb = static_cast<uint8_t *>(trampoline);
    memcpy(tb, entry, 16);
    uint32_t tail[2] = {0x58000050u, 0xD61F0200u};  // ldr x16,#8; br x16
    memcpy(tb + 16, tail, sizeof(tail));
    uint64_t continueAddress = reinterpret_cast<uint64_t>(entry) + 16;
    memcpy(tb + 24, &continueAddress, 8);
    sys_icache_invalidate(tb, kTrampolineBytes);
    if (mprotect(trampoline, kTrampolineBytes, PROT_READ | PROT_EXEC) != 0) {
        munmap(trampoline, kTrampolineBytes);
        if (error) *error = AvatarRoundError(@"无法将头像跳板设为可执行");
        return NO;
    }

    uint8_t patch[16];
    memcpy(patch, tail, sizeof(tail));
    uint64_t hookAddress = reinterpret_cast<uint64_t>(&WCRShapeDrawStub);
    memcpy(patch + 8, &hookAddress, 8);

    // 先发布跳板再改入口，避免入口已生效时桩读到空指针。
    gWCRShapeTrampoline = trampoline;
    NSError *patchError = nil;
    if (!WCRPatchCodeBytes(entry, patch, sizeof(patch), &patchError)) {
        gWCRShapeTrampoline = nullptr;
        munmap(trampoline, kTrampolineBytes);
        if (error) *error = patchError;
        return NO;
    }

    memcpy(gSavedEntry, current, sizeof(current));
    gEntry = entry;
    gInstalled.store(true);
    return YES;
}

BOOL WCRAvatarRoundUninstall(NSError **error) {
    if (!gInstalled.load()) return YES;
    NSError *patchError = nil;
    if (gEntry && !WCRPatchCodeBytes(gEntry, gSavedEntry, sizeof(gSavedEntry), &patchError)) {
        if (error) *error = patchError;
        return NO;
    }
    if (gWCRShapeTrampoline) {
        mprotect(gWCRShapeTrampoline, 32, PROT_READ | PROT_WRITE);
        munmap(gWCRShapeTrampoline, 32);
        gWCRShapeTrampoline = nullptr;
    }
    gEntry = nullptr;
    gInstalled.store(false);
    return YES;
}

BOOL WCRAvatarRoundIsInstalled(void) {
    return gInstalled.load();
}
