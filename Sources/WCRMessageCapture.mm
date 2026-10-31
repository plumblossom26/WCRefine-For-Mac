#import "WCRMessageCapture.h"
#import "WCRCodePatch.h"

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach-o/dyld.h>
#import <sys/mman.h>
#import <libkern/OSCacheControl.h>

#include <atomic>
#include <cstring>
#include <map>
#include <mutex>
#include <string>

// 消息终结器约定（270135 0x4CBC3AC / 270115 0x4B573B8）：
//   x0 = 消息对象
//   对象内偏移：+0x0C 消息类型(u32)、+0xF8 服务器消息 ID、+0x130 正文(libc++ string)
//   入口前 4 条指令含一条 b.eq（PC 相对），跳板里必须重编码，不能整块拷贝。
constexpr uint64_t kObjTypeOffset = 0x0C;
constexpr uint64_t kObjServerIDOffset = 0xF8;
constexpr uint64_t kObjContentOffset = 0x130;
constexpr size_t kTrampBytes = 48;
constexpr size_t kMaxCapturedMessages = 1024;

namespace {

std::atomic_bool gInstalled(false);
std::atomic_bool gCaptureContent(false);
std::atomic<uint64_t> gCaptureGeneration(0);
uint8_t *gEntryAddress = nullptr;
uint8_t gSavedEntry[16] = {};
void *gTrampoline = nullptr;

struct CapturedMessage {
    uint64_t type = 0;
    std::string content;
    uint32_t createTimeSec = 0;
};

std::mutex gMutex;
std::map<uint64_t, CapturedMessage> gCaptured;
uint64_t gCreateTimeSecOffset = 0;

std::atomic<WCRMessageCaptureObjectObserver> gObjectObserver{nullptr};

NSError *CaptureError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMac.MessageCapture"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"消息捕获错误"}];
}

bool IsAddressRangeReadable(const void *address, size_t length) {
    if (!address || length == 0) return false;
    uintptr_t current = reinterpret_cast<uintptr_t>(address);
    uintptr_t end = current + length;
    if (end < current) return false;

    while (current < end) {
        mach_vm_address_t region = static_cast<mach_vm_address_t>(current);
        mach_vm_size_t regionSize = 0;
        vm_region_basic_info_data_64_t info = {};
        mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t objectName = MACH_PORT_NULL;
        kern_return_t result = mach_vm_region(mach_task_self(),
                                              &region,
                                              &regionSize,
                                              VM_REGION_BASIC_INFO_64,
                                              reinterpret_cast<vm_region_info_t>(&info),
                                              &infoCount,
                                              &objectName);
        if (objectName != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), objectName);
        if (result != KERN_SUCCESS || regionSize == 0 ||
            region > current || (info.protection & VM_PROT_READ) == 0) {
            return false;
        }
        uintptr_t next = static_cast<uintptr_t>(region + regionSize);
        if (next <= current) return false;
        current = next;
    }
    return true;
}

bool ReadLibcppStringAt(const void *object, std::string &out) {
    const auto *bytes = reinterpret_cast<const uint8_t *>(object);
    if (!IsAddressRangeReadable(bytes, 24)) return false;

    const int8_t flag = static_cast<int8_t>(bytes[23]);
    if (flag >= 0) {
        size_t length = static_cast<uint8_t>(flag) & 0x7F;
        if (length > 22) return false;
        out.assign(reinterpret_cast<const char *>(bytes), length);
        return true;
    }

    const char *data = nullptr;
    uint64_t rawLength = 0;
    memcpy(&data, bytes, sizeof(data));
    memcpy(&rawLength, bytes + 8, sizeof(rawLength));
    size_t length = static_cast<size_t>(rawLength & 0x7FFFFFFFFFFFFFFFULL);
    if (!data || length == 0 || length > 8192 || !IsAddressRangeReadable(data, length)) {
        return false;
    }
    out.assign(data, length);
    return true;
}

}  // namespace

// 捕获点：由裸函数桩在保存全部寄存器后调用，x0 = 消息对象。
// 只做防御性读取与入库，任何异常都不得传播回微信。
extern "C" void WCRMessageCaptureCapturePoint(void *object) {
    if (!gInstalled.load() || !object) return;
    try {
        @try {
            WCRMessageCaptureObjectObserver observer = gObjectObserver.load();
            if (observer) observer(object);
            const auto *base = reinterpret_cast<const uint8_t *>(object);
            uint32_t type = 0;
            uint64_t serverID = 0;
            if (!IsAddressRangeReadable(base + kObjTypeOffset, sizeof(type)) ||
                !IsAddressRangeReadable(base + kObjServerIDOffset, sizeof(serverID))) {
                return;
            }
            memcpy(&type, base + kObjTypeOffset, sizeof(type));
            memcpy(&serverID, base + kObjServerIDOffset, sizeof(serverID));
            if (serverID == 0) return;

            const uint64_t generation = gCaptureGeneration.load(std::memory_order_relaxed);
            bool captureContent = gCaptureContent.load(std::memory_order_relaxed);
            std::string content;
            uint32_t createTimeSec = 0;
            if (captureContent) {
                if (IsAddressRangeReadable(base + kObjContentOffset, 24)) {
                    ReadLibcppStringAt(base + kObjContentOffset, content);
                }
                if (content.size() > 4096) content.resize(4096);
                if (gCreateTimeSecOffset != 0 &&
                    IsAddressRangeReadable(base + gCreateTimeSecOffset, sizeof(createTimeSec))) {
                    memcpy(&createTimeSec, base + gCreateTimeSecOffset, sizeof(createTimeSec));
                }
            }

            std::lock_guard<std::mutex> lock(gMutex);
            if (captureContent &&
                gCaptureGeneration.load(std::memory_order_relaxed) != generation) {
                captureContent = false;
            }
            if (gCaptured.find(serverID) == gCaptured.end() &&
                gCaptured.size() >= kMaxCapturedMessages) {
                gCaptured.erase(gCaptured.begin());
            }
            CapturedMessage &slot = gCaptured[serverID];
            uint32_t keptTime = slot.createTimeSec;
            slot.type = type;
            // 撤回前同一条消息会再进终结器，这时正文经常已经空了。
            // 空读不能盖掉已经记下的原文，否则提示会丢掉「撤回内容」。
            // 关闭正文捕获时仍清空，避免开关关掉之后继续留着正文。
            if (!captureContent) {
                slot.content.clear();
            } else if (!content.empty()) {
                slot.content = std::move(content);
            }
            slot.createTimeSec = captureContent && createTimeSec != 0 ? createTimeSec : keptTime;
        } @catch (id) {
        }
    } catch (...) {
    }
}

// 跳板目标地址，桩通过它进入跳板。C 链接以便裸汇编按符号引用。
extern "C" { void *gCaptureTrampolineTarget = nullptr; }

// 裸函数桩：被入口补丁（ldr x16/br x16）跳入。保存 x0-x18/x29/x30 →
// 调用捕获点（x0 原样作为参数）→ 恢复全部寄存器 → 跳到跳板执行原
// prologue 语义。NZCV 无需保存：跳板里的 cmp/ccmp 在 b.eq 前会重建标志位。
__attribute__((naked)) static void WCRCaptureStub(void) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-0xB0]!\n"
        "stp x0, x1, [sp, #0x10]\n"
        "stp x2, x3, [sp, #0x20]\n"
        "stp x4, x5, [sp, #0x30]\n"
        "stp x6, x7, [sp, #0x40]\n"
        "stp x8, x9, [sp, #0x50]\n"
        "stp x10, x11, [sp, #0x60]\n"
        "stp x12, x13, [sp, #0x70]\n"
        "stp x14, x15, [sp, #0x80]\n"
        "stp x16, x17, [sp, #0x90]\n"
        "str x18, [sp, #0xA0]\n"
        "bl _WCRMessageCaptureCapturePoint\n"
        "ldp x0, x1, [sp, #0x10]\n"
        "ldp x2, x3, [sp, #0x20]\n"
        "ldp x4, x5, [sp, #0x30]\n"
        "ldp x6, x7, [sp, #0x40]\n"
        "ldp x8, x9, [sp, #0x50]\n"
        "ldp x10, x11, [sp, #0x60]\n"
        "ldp x12, x13, [sp, #0x70]\n"
        "ldp x14, x15, [sp, #0x80]\n"
        "ldp x16, x17, [sp, #0x90]\n"
        "ldr x18, [sp, #0xA0]\n"
        "ldp x29, x30, [sp], #0xB0\n"
        "adrp x16, _gCaptureTrampolineTarget@PAGE\n"
        "add x16, x16, _gCaptureTrampolineTarget@PAGEOFF\n"
        "ldr x17, [x16]\n"
        "br x17\n"
    );
}

namespace {

void Put32(uint8_t *out, size_t offset, uint32_t value) {
    memcpy(out + offset, &value, sizeof(value));
}

void Put64(uint8_t *out, size_t offset, uint64_t value) {
    memcpy(out + offset, &value, sizeof(value));
}

constexpr uint32_t kLdrX17Pc8 = 0x58000051u;  // ldr x17, [pc, #8]
constexpr uint32_t kBrX17 = 0xD61F0220u;      // br x17

// 重编码 b.eq：imm19 相对当前指令，指向 entry + continueOffset。
uint32_t EncodeBEq(int64_t byteOffset) {
    const int64_t words = byteOffset / 4;
    return 0x54000000u | ((static_cast<uint32_t>(words) & 0x7FFFF) << 5) | 0x0u;  // cond=EQ
}

// 跳板布局（48 字节）：
//   [0x00] ldrb w8,[x0,#typeOff]        ← 原 insn1（非 PC 相对，直接拷贝）
//   [0x04] cmp  w8,#1                   ← 原 insn2
//   [0x08] ccmp w1,#0,#0,eq             ← 原 insn3
//   [0x0C] b.eq +0x14 → [0x20]          ← 原 insn4 重编码（内部短跳）
//   [0x10] ldr x17,[pc,#8] / br x17     → 回到 entry+0x10（原函数继续）
//   [0x18] <entry+0x10>
//   [0x20] ldr x17,[pc,#8] / br x17     → 原 b.eq 的目标（早退 ret 路径）
//   [0x28] <entry 的 b.eq 目标>
BOOL BuildTrampoline(uint64_t entryAddress,
                     uint8_t *trampolineOut,
                     size_t trampolineCap,
                     NSError **error) {
    if (!trampolineOut || trampolineCap < kTrampBytes) {
        if (error) *error = CaptureError(@"跳板缓冲区不足");
        return NO;
    }
    uint8_t *t = trampolineOut;
    Put32(t, 0x00, 0x39496008u);      // ldrb w8, [x0, #0x258]
    Put32(t, 0x04, 0x7100051Fu);      // cmp w8, #1
    Put32(t, 0x08, 0x7A400820u);      // ccmp w1, #0, #0, eq
    Put32(t, 0x0C, EncodeBEq(0x14));  // b.eq → 0x20
    Put32(t, 0x10, kLdrX17Pc8);
    Put32(t, 0x14, kBrX17);
    Put64(t, 0x18, entryAddress + 0x10);
    Put32(t, 0x20, kLdrX17Pc8);
    Put32(t, 0x24, kBrX17);
    // 原 b.eq（entry+0xC，imm19=0x1B）目标 = entry + 0xC + 0x6C = entry + 0x78
    Put64(t, 0x28, entryAddress + 0x78);
    sys_icache_invalidate(t, kTrampBytes);
    return YES;
}

}  // namespace

BOOL WCRMessageCaptureSupportsProfile(const WCRPatchProfile *profile) {
    return profile && profile->messageFinalizerAddress != 0 &&
           profile->messageFinalizerContinuation != 0 &&
           profile->messageServerIDOffset != 0 &&
           profile->messageTypeOffset != 0 && profile->messageContentOffset != 0;
}

BOOL WCRMessageCaptureInstall(const WCRPatchProfile *profile, NSError **error) {
    if (gInstalled.load()) return YES;
    if (!WCRMessageCaptureSupportsProfile(profile)) {
        if (error) *error = CaptureError(@"当前微信构建没有登记消息终结器几何信息");
        return NO;
    }

    const struct mach_header *found = nullptr;
    uintptr_t slide = 0;
    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const char *name = _dyld_get_image_name(index);
        if (!name) continue;
        std::string path(name);
        const char *suffix = "/Contents/Resources/wechat.dylib";
        const size_t suffixLength = strlen(suffix);
        if (path.size() < suffixLength ||
            path.compare(path.size() - suffixLength, suffixLength, suffix) != 0) {
            continue;
        }
        slide = static_cast<uintptr_t>(_dyld_get_image_vmaddr_slide(index));
        found = _dyld_get_image_header(index);
        break;
    }
    if (!found) {
        if (error) *error = CaptureError(@"wechat.dylib 尚未加载");
        return NO;
    }

    uint8_t *entry = reinterpret_cast<uint8_t *>(slide + profile->messageFinalizerAddress);
    if (!IsAddressRangeReadable(entry, sizeof(gSavedEntry)) ||
        memcmp(entry, profile->messageFinalizerPrologue, sizeof(gSavedEntry)) != 0) {
        if (error) *error = CaptureError(@"消息终结器入口字节不匹配，拒绝安装捕获 Hook");
        return NO;
    }

    void *trampoline = mmap(nullptr, kTrampBytes, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANON, -1, 0);
    if (trampoline == MAP_FAILED) {
        if (error) *error = CaptureError(@"无法分配消息捕获跳板");
        return NO;
    }
    if (!BuildTrampoline(
            reinterpret_cast<uint64_t>(entry),
            static_cast<uint8_t *>(trampoline), kTrampBytes, error)) {
        munmap(trampoline, kTrampBytes);
        return NO;
    }
    if (mprotect(trampoline, kTrampBytes, PROT_READ | PROT_EXEC) != 0) {
        int savedErrno = errno;
        munmap(trampoline, kTrampBytes);
        if (error) *error = CaptureError([NSString stringWithFormat:
            @"无法将消息捕获跳板设为可执行: %s", strerror(savedErrno)]);
        return NO;
    }

    uint8_t patch[16] = {};
    Put32(patch, 0, kLdrX17Pc8);
    Put32(patch, 4, kBrX17);
    uint64_t stubAddress = reinterpret_cast<uint64_t>(&WCRCaptureStub);
    memcpy(patch + 8, &stubAddress, sizeof(stubAddress));

    memcpy(gSavedEntry, entry, sizeof(gSavedEntry));
    gEntryAddress = entry;
    // 桩在恢复寄存器后会读取这个指针。发布之后不能再 munmap，
    // 入口字节改回去时，已经进桩的线程仍会跳进来。
    void *previousTrampoline = gCaptureTrampolineTarget;
    gTrampoline = trampoline;
    gCaptureTrampolineTarget = trampoline;

    if (!WCRPatchCodeBytes(entry, patch, sizeof(patch), error)) {
        gEntryAddress = nullptr;
        gTrampoline = previousTrampoline;
        gCaptureTrampolineTarget = previousTrampoline;
        if (previousTrampoline == nullptr) munmap(trampoline, kTrampBytes);
        return NO;
    }

    gCreateTimeSecOffset = profile->messageCreateTimeSecOffset;
    gInstalled.store(true);
    return YES;
}

BOOL WCRMessageCaptureUninstall(NSError **error) {
    if (!gInstalled.load()) return YES;
    if (gEntryAddress && !WCRPatchCodeBytes(gEntryAddress, gSavedEntry, sizeof(gSavedEntry), error)) {
        return NO;
    }
    // 入口已恢复。跳板留在原处：桩里还没读指针的线程仍要能跳回去。
    gInstalled.store(false);
    gEntryAddress = nullptr;
    WCRMessageCaptureSetContentCaptureEnabled(NO);
    return YES;
}

BOOL WCRMessageCaptureIsInstalled(void) {
    return gInstalled.load();
}

void WCRMessageCaptureSetObjectObserver(WCRMessageCaptureObjectObserver observer) {
    gObjectObserver.store(observer);
}

void WCRMessageCaptureSetContentCaptureEnabled(BOOL enabled) {
    if (enabled == YES) {
        gCaptureContent.store(true, std::memory_order_relaxed);
        return;
    }
    gCaptureContent.store(false, std::memory_order_relaxed);
    gCaptureGeneration.fetch_add(1, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(gMutex);
    gCaptured.clear();
}

NSString *WCRMessageCaptureContent(uint64_t serverID) {
    if (serverID == 0) return nil;
    std::lock_guard<std::mutex> lock(gMutex);
    auto it = gCaptured.find(serverID);
    if (it == gCaptured.end() || it->second.content.empty()) return nil;
    return [NSString stringWithUTF8String:it->second.content.c_str()] ?: nil;
}

NSUInteger WCRMessageCaptureType(uint64_t serverID) {
    if (serverID == 0) return 0;
    std::lock_guard<std::mutex> lock(gMutex);
    auto it = gCaptured.find(serverID);
    return it != gCaptured.end() ? static_cast<NSUInteger>(it->second.type) : 0;
}

uint32_t WCRMessageCaptureCreateTime(uint64_t serverID) {
    if (serverID == 0) return 0;
    std::lock_guard<std::mutex> lock(gMutex);
    auto it = gCaptured.find(serverID);
    return it != gCaptured.end() ? it->second.createTimeSec : 0;
}
