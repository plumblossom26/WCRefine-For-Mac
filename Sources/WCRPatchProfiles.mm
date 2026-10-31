#import "WCRPatchProfiles.h"
#import "WCRCodePatch.h"

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach-o/dyld.h>
#import <arpa/inet.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <libkern/OSCacheControl.h>
#import <sys/mman.h>
#import <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr const char *kBundleIdentifier = "com.tencent.xinWeChat";
constexpr const char *kWeChatResourcesSuffix = "/Contents/Resources/wechat.dylib";

constexpr uint32_t kArm64CpuType = CPU_TYPE_ARM64;

// Universal wechat.dylib SHA-256 evidence:
//   270135: 5f5a81c4d8b000dec1c7203738fc4dba75ce752b55874fc1b6b5869f9dfb1027
const WCRPatchProfile kProfiles[] = {
    {
        .shortVersion = "4.1.15",
        .buildVersion = "270135",
        .displayVersion = "4.1.15.55",
        .dylibSHA256 = "5f5a81c4d8b000dec1c7203738fc4dba75ce752b55874fc1b6b5869f9dfb1027",
        .patchAddress = 0x4d1fb48,
        .expectedBytes = {0x40, 0x10, 0x00, 0x34},
        .replacementBytes = {0x82, 0x00, 0x00, 0x14},
        .revokeParserAddress = 0x4d1f8d8,
        .revokePrologue = {0xA9BC5FF8, 0xA90157F6, 0xA9024FF4, 0xA9037BFD},
        .revokeNewMsgIdOffset = 0x1C8,
        .revokeReplaceMsgOffset = 0x1D0,
        .messageFinalizerAddress = 0x4CBC3AC,
        .messageFinalizerContinuation = 0x4CBC3B8,
        .messageFinalizerPrologue = {0x39496008, 0x7100051F, 0x7A400820, 0x54000360},
        .messageServerIDOffset = 0xF8,
        .messageTypeOffset = 0x0C,
        .messageContentOffset = 0x130,
        // 构造函数 0x4cbb198 str w,[msg,#0x114]；紧接着 umull #1000 写入 #0x100。
        // 0x278 字节的消息数组按 #0x114 归并（0x3219c38）。只给消息捕获用。
        .messageCreateTimeSecOffset = 0x114,
        .messageCreateTimeMsOffset = 0x100,
        // sub_4D1F8D8 的 revoketime 路径：content → +0x1D0，再 operator= 到这两处。
        .revokeDisplayCopyOffsetA = 0x218,
        .revokeDisplayCopyOffsetB = 0x230,
        // 气泡「转发」可见性 sub_4D3AE38。类型在 x0+8。类型 34 原样返回 0。
        // 序言是普通建栈，可搬进 16 字节跳板。不是发送函数，voiceSendAddress 仍为 0。
        .voiceMenuGateAddress = 0x4D3AE38,
        .voiceMenuGatePrologue = {0xD10103FF, 0xA9024FF4, 0xA9037BFD, 0x9100C3FD},
        // 文本气泡右键菜单收口。复读只登记 270135；其它构建保持置灰。
        .repeatMenuBuilderAddress = 0xCF46AC,
        .repeatMenuBuilderPrologue = {0xA9BA6FFC, 0xA90167FA, 0xA9025FF8, 0xA90357F6},
        .avatarShapeAddress = 0x1f3c2cc,
        .avatarShapePrologue = {0xD104C3FF, 0x6D0C2BEB, 0x6D0D23E9, 0xA90E67FA},
        // mmui::ChatMasterView::OnSelectedSession。只改前 12 字节（sub/stp/add），
        // 第 4 条 adrp 留在 0x1361c4。序言不匹配就拒绝安装。
        .sessionSelectAddress = 0x1361b8,
        .sessionSelectPrologue = {0xD100C3FF, 0xA9027BFD, 0x910083FD},
    },
};

NSString *WCRErrorString(NSString *message) {
    return message ?: @"未知错误";
}

NSError *WCRError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMac.Patch"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: WCRErrorString(message)}];
}

const WCRPatchProfile *WCRFindProfile(NSString *shortVersion, NSString *buildVersion) {
    for (const WCRPatchProfile &profile : kProfiles) {
        if (![shortVersion isEqualToString:@(profile.shortVersion)] ||
            ![buildVersion isEqualToString:@(profile.buildVersion)]) {
            continue;
        }
        return &profile;
    }
    return nullptr;
}

BOOL WCRFatArchArm64(const uint8_t *fileBytes,
                     size_t fileSize,
                     size_t *sliceOffset,
                     size_t *sliceSize,
                     NSError **error) {
    if (!fileBytes || fileSize < sizeof(uint32_t) || !sliceOffset || !sliceSize) {
        if (error) *error = WCRError(@"wechat.dylib 为空或长度不足");
        return NO;
    }
    uint32_t magicBE = 0;
    memcpy(&magicBE, fileBytes, sizeof(magicBE));
    magicBE = ntohl(magicBE);

    if (magicBE == FAT_MAGIC) {
        if (fileSize < 8) {
            if (error) *error = WCRError(@"FAT 头不完整");
            return NO;
        }
        uint32_t countBE = 0;
        memcpy(&countBE, fileBytes + 4, sizeof(countBE));
        uint32_t count = ntohl(countBE);
        if (count == 0 || count > 64) {
            if (error) *error = WCRError(@"FAT 架构数量非法");
            return NO;
        }
        size_t cursor = 8;
        for (uint32_t i = 0; i < count; ++i) {
            if (cursor > fileSize || fileSize - cursor < sizeof(fat_arch)) {
                if (error) *error = WCRError(@"FAT 架构表不完整");
                return NO;
            }
            fat_arch arch{};
            memcpy(&arch, fileBytes + cursor, sizeof(arch));
            cursor += sizeof(arch);
            uint32_t cpuType = ntohl(arch.cputype);
            uint32_t offset = ntohl(arch.offset);
            uint32_t size = ntohl(arch.size);
            if (cpuType != kArm64CpuType) continue;
            if (offset > fileSize || size > fileSize - offset) {
                if (error) *error = WCRError(@"FAT arm64 切片越界");
                return NO;
            }
            *sliceOffset = offset;
            *sliceSize = size;
            return YES;
        }
        if (error) *error = WCRError(@"微信不包含 arm64 架构；当前仅支持 Apple Silicon");
        return NO;
    }

    if (fileSize < sizeof(mach_header_64)) {
        if (error) *error = WCRError(@"Mach-O 头不完整");
        return NO;
    }
    mach_header_64 header{};
    memcpy(&header, fileBytes, sizeof(header));
    if (header.magic != MH_MAGIC_64 || header.cputype != kArm64CpuType) {
        if (error) *error = WCRError(@"wechat.dylib 不是 arm64 Mach-O");
        return NO;
    }
    *sliceOffset = 0;
    *sliceSize = fileSize;
    return YES;
}

BOOL WCRFileOffsetForVA(const uint8_t *slice,
                        size_t sliceSize,
                        uint64_t targetVA,
                        uint64_t *fileOffset,
                        NSError **error) {
    if (!slice || sliceSize < sizeof(mach_header_64) || !fileOffset) {
        if (error) *error = WCRError(@"Mach-O 头不完整");
        return NO;
    }
    mach_header_64 header{};
    memcpy(&header, slice, sizeof(header));
    if (header.magic != MH_MAGIC_64 || header.cputype != kArm64CpuType) {
        if (error) *error = WCRError(@"不支持的 Mach-O 架构");
        return NO;
    }

    size_t commandOffset = sizeof(mach_header_64);
    for (uint32_t i = 0; i < header.ncmds; ++i) {
        if (commandOffset > sliceSize || sliceSize - commandOffset < sizeof(load_command)) {
            if (error) *error = WCRError(@"Mach-O load command 越界");
            return NO;
        }
        load_command command{};
        memcpy(&command, slice + commandOffset, sizeof(command));
        if (command.cmdsize < sizeof(load_command) ||
            commandOffset > sliceSize || command.cmdsize > sliceSize - commandOffset) {
            if (error) *error = WCRError(@"Mach-O load command 长度非法");
            return NO;
        }
        if (command.cmd == LC_SEGMENT_64) {
            if (command.cmdsize < sizeof(segment_command_64)) {
                if (error) *error = WCRError(@"LC_SEGMENT_64 长度非法");
                return NO;
            }
            segment_command_64 segment{};
            memcpy(&segment, slice + commandOffset, sizeof(segment));
            if (targetVA >= segment.vmaddr && targetVA - segment.vmaddr < segment.vmsize) {
                uint64_t delta = targetVA - segment.vmaddr;
                if (delta >= segment.filesize) {
                    if (error) *error = WCRError(@"补丁地址位于未映射文件区间");
                    return NO;
                }
                uint64_t offset = segment.fileoff + delta;
                if (offset > sliceSize || sliceSize - offset < 4) {
                    if (error) *error = WCRError(@"补丁地址映射越界");
                    return NO;
                }
                *fileOffset = offset;
                return YES;
            }
        }
        commandOffset += command.cmdsize;
    }

    if (error) *error = WCRError(@"未找到补丁地址所属的 Mach-O segment");
    return NO;
}

BOOL WCRVerifyDWordsAtVA(const uint8_t *slice,
                         size_t sliceSize,
                         uint64_t targetVA,
                         const uint32_t *expected,
                         size_t count,
                         NSString *label,
                         NSError **error) {
    if (!expected || count == 0) return YES;
    uint64_t offset = 0;
    if (!WCRFileOffsetForVA(slice, sliceSize, targetVA, &offset, error)) return NO;
    if (offset > sliceSize || count > (sliceSize - offset) / sizeof(uint32_t)) {
        if (error) *error = WCRError([NSString stringWithFormat:@"%@ 序言越界", label ?: @"入口"]);
        return NO;
    }
    for (size_t index = 0; index < count; ++index) {
        uint32_t actual = 0;
        memcpy(&actual, slice + offset + index * sizeof(uint32_t), sizeof(actual));
        if (actual != expected[index]) {
            if (error) {
                *error = WCRError([NSString stringWithFormat:
                    @"%@ 序言不匹配（0x%llX: 0x%08X != 0x%08X）",
                    label ?: @"入口",
                    (unsigned long long)(targetVA + index * 4),
                    actual,
                    expected[index]]);
            }
            return NO;
        }
    }
    return YES;
}

NSString *WCRDataSHA256(NSData *data) {
    if (!data) return nil;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    size_t remaining = data.length;
    while (remaining > 0) {
        CC_LONG chunk = static_cast<CC_LONG>(std::min<size_t>(remaining, 1024 * 1024));
        CC_SHA256_Update(&context, bytes, chunk);
        bytes += chunk;
        remaining -= chunk;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {};
    CC_SHA256_Final(digest, &context);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1] = {};
    for (size_t index = 0; index < CC_SHA256_DIGEST_LENGTH; ++index) {
        snprintf(hex + index * 2, sizeof(hex) - index * 2, "%02x", digest[index]);
    }
    return @(hex);
}

BOOL WCRCheckDylibProfile(NSString *path,
                          const WCRPatchProfile *profile,
                          BOOL *matches,
                          BOOL *alreadyPatched,
                          NSString * _Nullable * _Nullable failureReason,
                          NSError **error) {
    if (!profile || !matches || !alreadyPatched) {
        if (error) *error = WCRError(@"缺少版本配置");
        return NO;
    }
    *matches = NO;
    *alreadyPatched = NO;
    if (failureReason) *failureReason = nil;

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path
                                         options:NSDataReadingMappedIfSafe
                                           error:&readError];
    if (!data) {
        if (error) *error = readError ?: WCRError(@"无法读取 wechat.dylib");
        return NO;
    }
    NSString *actualHash = WCRDataSHA256(data);
    NSString *expectedHash = profile->dylibSHA256 ? @(profile->dylibSHA256) : @"";
    if (expectedHash.length != 64) {
        if (error) *error = WCRError(@"版本配置缺少完整 wechat.dylib SHA-256");
        return NO;
    }
    if (![actualHash isEqualToString:expectedHash]) {
        if (failureReason) {
            *failureReason = [NSString stringWithFormat:
                @"wechat.dylib SHA-256 不匹配（当前 %@）", actualHash ?: @"未知"];
        }
        return YES;
    }

    size_t sliceOffset = 0;
    size_t sliceSize = 0;
    if (!WCRFatArchArm64(static_cast<const uint8_t *>(data.bytes),
                         data.length,
                         &sliceOffset,
                         &sliceSize,
                         error)) {
        return NO;
    }
    const uint8_t *slice = static_cast<const uint8_t *>(data.bytes) + sliceOffset;

    uint64_t patchOffset = 0;
    if (!WCRFileOffsetForVA(slice, sliceSize, profile->patchAddress, &patchOffset, error)) {
        return NO;
    }
    if (patchOffset > sliceSize || sliceSize - patchOffset < sizeof(profile->expectedBytes)) {
        if (error) *error = WCRError(@"补丁地址映射越界");
        return NO;
    }
    const uint8_t *actual = slice + patchOffset;
    if (memcmp(actual, profile->expectedBytes, sizeof(profile->expectedBytes)) == 0) {
        *alreadyPatched = NO;
    } else if (memcmp(actual, profile->replacementBytes, sizeof(profile->replacementBytes)) == 0) {
        *alreadyPatched = YES;
    } else {
        NSMutableString *bytes = [NSMutableString string];
        for (size_t index = 0; index < sizeof(profile->expectedBytes); ++index) {
            [bytes appendFormat:@"%02X", actual[index]];
        }
        if (failureReason) {
            *failureReason = [NSString stringWithFormat:@"补丁点字节不匹配（当前 %@）", bytes];
        }
        return YES;
    }

    struct EntryCheck {
        uint64_t address;
        const uint32_t *words;
        size_t count;
        NSString *label;
    };
    EntryCheck checks[] = {
        {profile->revokeParserAddress, profile->revokePrologue, 4, @"撤回解析入口"},
        {profile->messageFinalizerAddress, profile->messageFinalizerPrologue, 4, @"消息终结器"},
        {profile->voiceSendAddress, profile->voiceSendPrologue, 4, @"语音发送入口"},
        {profile->voiceMenuGateAddress, profile->voiceMenuGatePrologue, 4, @"语音菜单入口"},
        {profile->repeatMenuBuilderAddress, profile->repeatMenuBuilderPrologue, 4, @"复读菜单入口"},
        {profile->avatarShapeAddress, profile->avatarShapePrologue, 4, @"头像绘制入口"},
        {profile->sessionSelectAddress, profile->sessionSelectPrologue, 3, @"会话切换入口"},
    };
    for (const EntryCheck &check : checks) {
        if (check.address == 0) continue;
        NSError *verifyError = nil;
        if (!WCRVerifyDWordsAtVA(slice, sliceSize, check.address, check.words, check.count,
                                 check.label, &verifyError)) {
            if (failureReason) *failureReason = verifyError.localizedDescription;
            return YES;
        }
    }

    *matches = YES;
    return YES;
}

BOOL WCREnsureArm64Dylib(NSString *path, NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
    if (!data) return NO;
    size_t sliceOffset = 0;
    size_t sliceSize = 0;
    return WCRFatArchArm64(static_cast<const uint8_t *>(data.bytes),
                           data.length,
                           &sliceOffset,
                           &sliceSize,
                           error);
}

NSDictionary *WCRInfoPlist(NSString *appPath) {
    NSString *infoPath = [appPath stringByAppendingPathComponent:@"Contents/Info.plist"];
    return [NSDictionary dictionaryWithContentsOfFile:infoPath];
}

NSString *WCRDylibPath(NSString *appPath) {
    return [appPath stringByAppendingPathComponent:@"Contents/Resources/wechat.dylib"];
}

const void *WCRFindLoadedWeChatDylib(uintptr_t *slideOut) {
    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const char *imageName = _dyld_get_image_name(index);
        if (!imageName) continue;
        std::string path(imageName);
        if (path.size() < strlen(kWeChatResourcesSuffix) ||
            path.compare(path.size() - strlen(kWeChatResourcesSuffix),
                         strlen(kWeChatResourcesSuffix),
                         kWeChatResourcesSuffix) != 0) {
            continue;
        }
        if (slideOut) *slideOut = (uintptr_t)_dyld_get_image_vmaddr_slide(index);
        return _dyld_get_image_header(index);
    }
    return nullptr;
}

BOOL WCRWriteProcessBytes(uint8_t *target,
                          const uint8_t *bytes,
                          size_t length,
                          NSError **error) {
    return WCRPatchCodeBytes(target, bytes, length, error);
}

const WCRPatchProfile *WCRProfileForMainBundle(NSError **error) {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *bundleID = bundle.bundleIdentifier ?: @"";
    NSString *shortVersion = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSString *buildVersion = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"";
    const char *selfTestValue = getenv("WCR_MAC_SELFTEST");
    BOOL selfTest = selfTestValue && strcmp(selfTestValue, "1") == 0;
    if (!WCRHostBundleIdentifierAllowed(bundleID, selfTest)) {
        if (error) *error = WCRError(@"插件只能加载到微信进程");
        return nullptr;
    }
    const WCRPatchProfile *profile = WCRFindProfile(shortVersion, buildVersion);
    if (!profile) {
        if (error) {
            *error = WCRError([NSString stringWithFormat:@"暂不支持当前微信构建 %@（%@）", buildVersion, shortVersion]);
        }
        return nullptr;
    }
    return profile;
}

BOOL WCRCheckCurrentProcessBytes(const WCRPatchProfile *profile,
                                 WCRPatchState *state,
                                 NSError **error) {
    if (!profile) {
        if (error) *error = WCRError(@"缺少版本配置");
        return NO;
    }
    uintptr_t slide = 0;
    if (!WCRFindLoadedWeChatDylib(&slide)) {
        if (error) *error = WCRError(@"wechat.dylib 尚未加载");
        return NO;
    }
    uint8_t *address = (uint8_t *)(slide + profile->patchAddress);
    std::array<uint8_t, 4> current{};
    memcpy(current.data(), address, current.size());
    if (memcmp(current.data(), profile->expectedBytes, current.size()) == 0) {
        if (state) *state = WCRPatchStatePristine;
        return YES;
    }
    if (memcmp(current.data(), profile->replacementBytes, current.size()) == 0) {
        if (state) *state = WCRPatchStateApplied;
        return YES;
    }
    if (error) {
        NSMutableString *actual = [NSMutableString string];
        for (uint8_t byte : current) [actual appendFormat:@"%02X", byte];
        *error = WCRError([NSString stringWithFormat:@"补丁点字节不匹配（当前 %@）", actual]);
    }
    if (state) *state = WCRPatchStateInvalidBytes;
    return NO;
}

}  // namespace

BOOL WCRHostBundleIdentifierAllowed(NSString *bundleIdentifier, BOOL selfTest) {
    if (bundleIdentifier.length == 0) return NO;
    if ([bundleIdentifier isEqualToString:@(kBundleIdentifier)]) return YES;
    if ([bundleIdentifier hasPrefix:@"com.tencent.xinWeChat.WCRefineMulti"]) return YES;
    return selfTest && [bundleIdentifier hasPrefix:@"com.tencent.xinWeChat.WCRefineTest"];
}

const WCRPatchProfile *WCRCurrentProcessProfile(NSError **error) {
    return WCRProfileForMainBundle(error);
}

BOOL WCRInspectWeChatApp(NSString *appPath, WCRAppInspection *inspection, NSError **error) {
    if (!inspection) {
        if (error) *error = WCRError(@"缺少检查结果");
        return NO;
    }
    *inspection = {};
    inspection->shortVersion = @"";
    inspection->buildVersion = @"";
    inspection->wechatDylibPath = @"";
    inspection->failureReason = @"";

    NSDictionary *info = WCRInfoPlist(appPath);
    if (!info) {
        if (error) *error = WCRError(@"找不到微信 Info.plist");
        return NO;
    }
    NSString *bundleID = info[@"CFBundleIdentifier"] ?: @"";
    NSString *shortVersion = info[@"CFBundleShortVersionString"] ?: @"";
    NSString *buildVersion = info[@"CFBundleVersion"] ?: @"";
    inspection->shortVersion = shortVersion;
    inspection->buildVersion = buildVersion;
    if (![bundleID isEqualToString:@(kBundleIdentifier)]) {
        if (error) *error = WCRError(@"目标不是微信（bundle id 不匹配）");
        return NO;
    }

    NSString *dylibPath = WCRDylibPath(appPath);
    if (![[NSFileManager defaultManager] fileExistsAtPath:dylibPath]) {
        if (error) *error = WCRError(@"找不到 Contents/Resources/wechat.dylib");
        return NO;
    }
    inspection->wechatDylibPath = dylibPath;
    if (!WCREnsureArm64Dylib(dylibPath, error)) return NO;

    const WCRPatchProfile *profile = WCRFindProfile(shortVersion, buildVersion);
    if (!profile) {
        inspection->supported = NO;
        inspection->failureReason = [NSString stringWithFormat:@"暂不支持微信 %@（%@）", buildVersion, shortVersion];
        return YES;
    }

    BOOL matches = NO;
    BOOL alreadyPatched = NO;
    NSString *failureReason = nil;
    if (!WCRCheckDylibProfile(dylibPath, profile, &matches, &alreadyPatched,
                              &failureReason, error)) {
        return NO;
    }
    inspection->profile = *profile;
    inspection->supported = matches;
    inspection->alreadyPatched = alreadyPatched;
    inspection->failureReason = failureReason ?: @"";
    return YES;
}

BOOL WCRApplyAntiRevokePatch(NSError **error) {
    const WCRPatchProfile *profile = WCRProfileForMainBundle(error);
    if (!profile) return NO;
    WCRPatchState state = WCRPatchStateUnavailable;
    if (!WCRCheckCurrentProcessBytes(profile, &state, error)) return NO;
    if (state == WCRPatchStateApplied) return YES;

    uintptr_t slide = 0;
    if (!WCRFindLoadedWeChatDylib(&slide)) {
        if (error) *error = WCRError(@"wechat.dylib 尚未加载");
        return NO;
    }
    return WCRWriteProcessBytes((uint8_t *)(slide + profile->patchAddress),
                                profile->replacementBytes,
                                sizeof(profile->replacementBytes),
                                error);
}

BOOL WCRRestoreAntiRevokePatch(NSError **error) {
    const WCRPatchProfile *profile = WCRProfileForMainBundle(error);
    if (!profile) return NO;
    WCRPatchState state = WCRPatchStateUnavailable;
    if (!WCRCheckCurrentProcessBytes(profile, &state, error)) return NO;
    if (state == WCRPatchStatePristine) return YES;

    uintptr_t slide = 0;
    if (!WCRFindLoadedWeChatDylib(&slide)) {
        if (error) *error = WCRError(@"wechat.dylib 尚未加载");
        return NO;
    }
    return WCRWriteProcessBytes((uint8_t *)(slide + profile->patchAddress),
                                profile->expectedBytes,
                                sizeof(profile->expectedBytes),
                                error);
}

WCRPatchState WCRCurrentProcessPatchState(NSError **error) {
    const WCRPatchProfile *profile = WCRProfileForMainBundle(error);
    if (!profile) return WCRPatchStateUnavailable;
    WCRPatchState state = WCRPatchStateUnavailable;
    if (!WCRCheckCurrentProcessBytes(profile, &state, error)) return state;
    return state;
}

NSArray<NSString *> *WCRSupportedBuildDescriptions(void) {
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    for (const WCRPatchProfile &profile : kProfiles) {
        [rows addObject:[NSString stringWithFormat:@"%@（%@）",
                                                   @(profile.displayVersion),
                                                   @(profile.buildVersion)]];
    }
    return rows;
}
