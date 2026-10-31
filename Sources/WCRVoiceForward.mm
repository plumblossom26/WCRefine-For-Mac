#import "WCRVoiceForward.h"

#import "WCRCodePatch.h"

#import <Foundation/Foundation.h>

#import <atomic>
#import <cstring>
#import <mach-o/dyld.h>
#import <sys/mman.h>
#import <libkern/OSCacheControl.h>

namespace {

// 270135 气泡「转发...」可见性：wechat.dylib+voiceMenuGateAddress
// （sub_4D3AE38）。x0 是菜单对象 +0x120，线类型在 +8。
// 类型 1 把 w0 留成 1 直接返回。类型 34 落到 mov w0,#0 再返回，没有别的写内存。
// 钩子只对类型 34 返回 1，其余类型走搬走的原函数。这不是发送函数。
constexpr uint32_t kVoiceWireType = 34;
constexpr size_t kTypeOffset = 8;
constexpr size_t kEntryBytes = 16;
constexpr size_t kTrampolineBytes = 32;

using VoiceMenuGateFn = uint32_t (*)(void *message);

std::atomic_bool gInstalled(false);
std::atomic<VoiceMenuGateFn> gOriginal{nullptr};
uint8_t gSavedEntry[kEntryBytes];
uint8_t *gEntry = nullptr;
void *gTrampoline = nullptr;

NSError *WCRVoiceForwardError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMac.VoiceForward"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"语音转发错误"}];
}

uint32_t WCRVoiceMenuGate(void *message) {
    if (message) {
        uint32_t type = 0;
        memcpy(&type, static_cast<const uint8_t *>(message) + kTypeOffset, sizeof(type));
        if (type == kVoiceWireType) return 1;
    }
    VoiceMenuGateFn original = gOriginal.load(std::memory_order_acquire);
    if (!original) return 0;
    return original(message);
}

bool WCRFindWeChatSlide(uintptr_t *slide) {
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/wechat.dylib")) {
            *slide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
            return true;
        }
    }
    return false;
}

}  // namespace

BOOL WCRVoiceForwardSupportsProfile(const WCRPatchProfile *profile) {
    return profile && profile->voiceMenuGateAddress != 0;
}

BOOL WCRVoiceForwardInstall(const WCRPatchProfile *profile, NSError **error) {
    if (gInstalled.load()) return YES;
    // 发送管线 voiceSendAddress / voiceDataOffset / voiceDurationOffset /
    // voiceFormatOffset 仍未登记。这里只改菜单可见性，缺了也不拦。
    if (!profile || profile->voiceMenuGateAddress == 0) {
        if (error) {
            *error = WCRVoiceForwardError(
                @"当前微信构建尚未登记语音转发菜单入口");
        }
        return NO;
    }

    uintptr_t slide = 0;
    if (!WCRFindWeChatSlide(&slide)) {
        if (error) *error = WCRVoiceForwardError(@"wechat.dylib 尚未加载");
        return NO;
    }

    uint8_t *entry = reinterpret_cast<uint8_t *>(slide + profile->voiceMenuGateAddress);
    uint8_t current[kEntryBytes];
    memcpy(current, entry, sizeof(current));
    uint8_t expected[kEntryBytes];
    for (int k = 0; k < 4; ++k) {
        memcpy(expected + 4 * k, &profile->voiceMenuGatePrologue[k], 4);
    }
    if (memcmp(current, expected, sizeof(current)) != 0) {
        NSMutableString *actual = [NSMutableString string];
        for (size_t k = 0; k < sizeof(current); ++k) [actual appendFormat:@"%02x", current[k]];
        if (error) {
            *error = WCRVoiceForwardError([NSString stringWithFormat:
                @"语音转发菜单入口字节不匹配（当前 %@）", actual]);
        }
        return NO;
    }

    void *trampoline = mmap(nullptr, kTrampolineBytes, PROT_READ | PROT_WRITE,
                            MAP_ANON | MAP_PRIVATE, -1, 0);
    if (trampoline == MAP_FAILED) {
        if (error) *error = WCRVoiceForwardError(@"无法分配语音转发跳板");
        return NO;
    }
    uint8_t *trampolineBytes = static_cast<uint8_t *>(trampoline);
    memcpy(trampolineBytes, entry, kEntryBytes);
    uint32_t tail[2] = {0x58000050u, 0xD61F0200u};  // ldr x16, #8; br x16
    memcpy(trampolineBytes + kEntryBytes, tail, sizeof(tail));
    uint64_t continueAddress = reinterpret_cast<uint64_t>(entry) + kEntryBytes;
    memcpy(trampolineBytes + 24, &continueAddress, sizeof(continueAddress));
    sys_icache_invalidate(trampolineBytes, kTrampolineBytes);
    if (mprotect(trampoline, kTrampolineBytes, PROT_READ | PROT_EXEC) != 0) {
        munmap(trampoline, kTrampolineBytes);
        if (error) *error = WCRVoiceForwardError(@"无法将语音转发跳板设为可执行");
        return NO;
    }

    uint8_t patch[kEntryBytes];
    memcpy(patch, tail, sizeof(tail));
    uint64_t hookAddress = reinterpret_cast<uint64_t>(&WCRVoiceMenuGate);
    memcpy(patch + 8, &hookAddress, sizeof(hookAddress));

    gTrampoline = trampoline;
    gOriginal.store(reinterpret_cast<VoiceMenuGateFn>(trampoline), std::memory_order_release);
    NSError *patchError = nil;
    if (!WCRPatchCodeBytes(entry, patch, sizeof(patch), &patchError)) {
        gOriginal.store(nullptr, std::memory_order_release);
        gTrampoline = nullptr;
        mprotect(trampoline, kTrampolineBytes, PROT_READ | PROT_WRITE);
        munmap(trampoline, kTrampolineBytes);
        if (error) *error = patchError;
        return NO;
    }

    memcpy(gSavedEntry, current, sizeof(current));
    gEntry = entry;
    gInstalled.store(true);
    return YES;
}

BOOL WCRVoiceForwardUninstall(NSError **error) {
    if (!gInstalled.load()) return YES;
    NSError *patchError = nil;
    if (gEntry && !WCRPatchCodeBytes(gEntry, gSavedEntry, sizeof(gSavedEntry), &patchError)) {
        if (error) *error = patchError;
        return NO;
    }
    gOriginal.store(nullptr, std::memory_order_release);
    if (gTrampoline) {
        mprotect(gTrampoline, kTrampolineBytes, PROT_READ | PROT_WRITE);
        munmap(gTrampoline, kTrampolineBytes);
        gTrampoline = nullptr;
    }
    gEntry = nullptr;
    gInstalled.store(false);
    return YES;
}

BOOL WCRVoiceForwardIsInstalled(void) {
    return gInstalled.load();
}
