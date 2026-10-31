#import "WCRSessionSelect.h"

#import "WCRCodePatch.h"
#import "WCROriginalID.h"

#import <Foundation/Foundation.h>
#import <libkern/OSCacheControl.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach-o/dyld.h>
#import <sys/mman.h>

#include <atomic>
#include <cstring>

namespace {

// OnSelectedSession 的发射桩在 0x1361b8。x0 是 ChatMasterView，x1 是
// libc++ std::string*（用户名）。前三条是普通建栈，可以原样搬走；
// 第四条是 adrp，必须留在原地址执行。所以入口只改 12 字节，
// 经附近的绝对跳板进本 dylib 的桩，再回放到入口 +12。
constexpr size_t kPatchBytes = 12;
constexpr uint32_t kLdrX16Pc8 = 0x58000050u;
constexpr uint32_t kBrX16 = 0xD61F0200u;

std::atomic_bool gInstalled{false};
uint8_t gSavedEntry[kPatchBytes];
uint8_t *gEntry = nullptr;
void *gIsland = nullptr;
void *gReplay = nullptr;
vm_size_t gPage = 0;

extern "C" {
void *gWCRSessionReplay = nullptr;
}

NSError *SessionError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMac.SessionSelect"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"会话切换钩子错误"}];
}

bool Readable(const void *address, size_t length) {
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

bool FindResourcesSlide(uintptr_t *slide) {
    const char *suffix = "/Contents/Resources/wechat.dylib";
    const size_t suffixLength = strlen(suffix);
    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const char *name = _dyld_get_image_name(index);
        if (!name) continue;
        size_t length = strlen(name);
        if (length < suffixLength ||
            memcmp(name + length - suffixLength, suffix, suffixLength) != 0) {
            continue;
        }
        *slide = static_cast<uintptr_t>(_dyld_get_image_vmaddr_slide(index));
        return true;
    }
    return false;
}

uint32_t EncodeAdrp(int64_t pageDelta, uint32_t rd) {
    uint32_t imm = static_cast<uint32_t>(pageDelta) & 0x1FFFFFu;
    uint32_t immlo = imm & 3u;
    uint32_t immhi = (imm >> 2) & 0x7FFFFu;
    return 0x90000000u | (immlo << 29) | (immhi << 5) | (rd & 31u);
}

uint32_t EncodeAdd(uint32_t rd, uint32_t rn, uint32_t imm12) {
    return 0x91000000u | ((imm12 & 0xFFFu) << 10) | ((rn & 31u) << 5) | (rd & 31u);
}

uint32_t EncodeBr(uint32_t rn) {
    return 0xD61F0000u | ((rn & 31u) << 5);
}

void Put32(void *base, size_t offset, uint32_t value) {
    memcpy(static_cast<uint8_t *>(base) + offset, &value, sizeof(value));
}

// adrp 只有 ±4GB。在入口附近找一页空闲地址，放 16 字节绝对跳板。
void *AllocateIsland(uintptr_t target, vm_size_t page) {
    const uintptr_t window = 0x80000000ULL;
    const int64_t kMinPage = -(1 << 20);
    const int64_t kMaxPage = 0xFFFFF;
    auto inRange = [&](uintptr_t address) {
        int64_t pages = static_cast<int64_t>(address >> 12) - static_cast<int64_t>(target >> 12);
        return pages >= kMinPage && pages <= kMaxPage;
    };
    auto tryHint = [&](uintptr_t hint) -> void * {
        if (!inRange(hint)) return nullptr;
        void *mapped = mmap(reinterpret_cast<void *>(hint), page, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANON, -1, 0);
        if (mapped == MAP_FAILED) return nullptr;
        if (inRange(reinterpret_cast<uintptr_t>(mapped))) return mapped;
        munmap(mapped, page);
        return nullptr;
    };

    uintptr_t start = target > window ? target - window : 0;
    mach_vm_address_t addr = start;
    mach_vm_address_t limit = target + window;
    while (addr < limit) {
        mach_vm_address_t region = addr;
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

        uintptr_t gapEnd = result == KERN_SUCCESS ? static_cast<uintptr_t>(region) : limit;
        if (gapEnd > limit) gapEnd = limit;
        if (gapEnd > addr && gapEnd - addr >= page) {
            uintptr_t aligned = (addr + page - 1) & ~(static_cast<uintptr_t>(page) - 1);
            uintptr_t last = (gapEnd - page) & ~(static_cast<uintptr_t>(page) - 1);
            if (aligned <= last && last + page <= gapEnd) {
                uintptr_t desired = target & ~(static_cast<uintptr_t>(page) - 1);
                if (desired < aligned) desired = aligned;
                if (desired > last) desired = last;
                if (void *mapped = tryHint(desired)) return mapped;
            }
        }
        if (result != KERN_SUCCESS) break;
        uintptr_t next = static_cast<uintptr_t>(region + regionSize);
        if (next <= addr) break;
        addr = next;
    }
    return nullptr;
}

}  // namespace

// 保存 x0–x18 后，把 x1 的 std::string* 交给记录表。x16 在进来之前已被跳板用掉，
// 它在函数入口是临时寄存器，原函数接着用的是 x8。
__attribute__((naked, visibility("hidden"))) static void WCRSessionStub(void) {
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
        "mov x0, x1\n"
        "bl _WCROriginalIDNoteSelectedUsername\n"
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
        "adrp x16, _gWCRSessionReplay@PAGE\n"
        "add x16, x16, _gWCRSessionReplay@PAGEOFF\n"
        "ldr x17, [x16]\n"
        "br x17\n"
    );
}

BOOL WCRSessionSelectInstall(const WCRPatchProfile *profile, NSError **error) {
    if (gInstalled.load()) return YES;
    if (EncodeAdd(29, 31, 0x20) != 0x910083FDu || EncodeBr(16) != kBrX16) {
        if (error) *error = SessionError(@"会话切换跳板编码自检失败");
        return NO;
    }
    if (!profile || profile->sessionSelectAddress == 0) {
        if (error) *error = SessionError(@"当前微信构建没有登记会话切换入口");
        return NO;
    }

    uintptr_t slide = 0;
    if (!FindResourcesSlide(&slide)) {
        if (error) *error = SessionError(@"wechat.dylib 尚未加载");
        return NO;
    }

    auto *entry = reinterpret_cast<uint8_t *>(slide + profile->sessionSelectAddress);
    if (!Readable(entry, kPatchBytes) ||
        memcmp(entry, profile->sessionSelectPrologue, kPatchBytes) != 0) {
        if (error) *error = SessionError(@"会话切换入口字节不匹配，拒绝安装");
        return NO;
    }

    vm_size_t page = vm_page_size;
    if (page < 0x1000) page = 0x1000;
    void *island = AllocateIsland(reinterpret_cast<uintptr_t>(entry), page);
    if (!island) {
        if (error) *error = SessionError(@"无法在会话切换入口附近分配跳板");
        return NO;
    }
    void *replay = mmap(nullptr, page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (replay == MAP_FAILED) {
        munmap(island, page);
        if (error) *error = SessionError(@"无法分配会话切换回放跳板");
        return NO;
    }

    memcpy(replay, entry, kPatchBytes);
    Put32(replay, 12, kLdrX16Pc8);
    Put32(replay, 16, kBrX16);
    uint64_t resume = reinterpret_cast<uint64_t>(entry) + kPatchBytes;
    memcpy(static_cast<uint8_t *>(replay) + 20, &resume, sizeof(resume));
    sys_icache_invalidate(replay, 32);

    Put32(island, 0, kLdrX16Pc8);
    Put32(island, 4, kBrX16);
    uint64_t stub = reinterpret_cast<uint64_t>(&WCRSessionStub);
    memcpy(static_cast<uint8_t *>(island) + 8, &stub, sizeof(stub));
    sys_icache_invalidate(island, 16);

    if (mprotect(replay, page, PROT_READ | PROT_EXEC) != 0 ||
        mprotect(island, page, PROT_READ | PROT_EXEC) != 0) {
        munmap(island, page);
        munmap(replay, page);
        if (error) *error = SessionError(@"无法将会话切换跳板设为可执行");
        return NO;
    }

    int64_t pages = static_cast<int64_t>(reinterpret_cast<uintptr_t>(island) >> 12) -
                    static_cast<int64_t>(reinterpret_cast<uintptr_t>(entry) >> 12);
    uint32_t pageoff = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(island) & 0xFFF);
    uint8_t patch[kPatchBytes] = {};
    Put32(patch, 0, EncodeAdrp(pages, 16));
    Put32(patch, 4, EncodeAdd(16, 16, pageoff));
    Put32(patch, 8, EncodeBr(16));

    void *previousReplay = gWCRSessionReplay;
    gWCRSessionReplay = replay;
    memcpy(gSavedEntry, entry, kPatchBytes);
    gEntry = entry;
    if (!WCRPatchCodeBytes(entry, patch, kPatchBytes, error)) {
        gWCRSessionReplay = previousReplay;
        gEntry = nullptr;
        munmap(island, page);
        munmap(replay, page);
        return NO;
    }

    gIsland = island;
    gReplay = replay;
    gPage = page;
    gInstalled.store(true);
    return YES;
}

BOOL WCRSessionSelectUninstall(NSError **error) {
    if (!gInstalled.load()) return YES;
    if (gEntry && !WCRPatchCodeBytes(gEntry, gSavedEntry, kPatchBytes, error)) return NO;
    // 入口已恢复。跳板留着：已经进桩的线程还要能回到原函数。
    gInstalled.store(false);
    gEntry = nullptr;
    return YES;
}

BOOL WCRSessionSelectIsInstalled(void) {
    return gInstalled.load();
}
