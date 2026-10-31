#import "WCRCodePatch.h"

#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <sys/mman.h>
#import <libkern/OSCacheControl.h>

#include <cerrno>
#include <cstring>
#include <unistd.h>

static NSError *WCRCodePatchError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMac.CodePatch"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"代码页写入失败"}];
}

BOOL WCRPatchCodeBytes(void *destination,
                       const void *bytes,
                       size_t length,
                       NSError **error) {
    if (!destination || !bytes || length == 0) {
        if (error) *error = WCRCodePatchError(@"无效的代码补丁参数");
        return NO;
    }

    const size_t pageSize = static_cast<size_t>(getpagesize());
    uintptr_t start = reinterpret_cast<uintptr_t>(destination);
    uintptr_t page = start & ~(pageSize - 1);
    size_t offset = start - page;
    if (offset + length > pageSize) {
        if (error) *error = WCRCodePatchError(@"代码补丁跨越内存页，拒绝写入");
        return NO;
    }

    void *copy = mmap(nullptr, pageSize, PROT_READ | PROT_WRITE,
                      MAP_ANON | MAP_PRIVATE, -1, 0);
    if (copy == MAP_FAILED) {
        if (error) {
            *error = WCRCodePatchError([NSString stringWithFormat:
                @"无法分配代码页副本: %s", strerror(errno)]);
        }
        return NO;
    }

    memcpy(copy, reinterpret_cast<const void *>(page), pageSize);
    memcpy(static_cast<uint8_t *>(copy) + offset, bytes, length);

    if (mprotect(copy, pageSize, PROT_READ | PROT_EXEC) != 0) {
        int savedErrno = errno;
        munmap(copy, pageSize);
        if (error) {
            *error = WCRCodePatchError([NSString stringWithFormat:
                @"无法设置代码页副本权限: %s", strerror(savedErrno)]);
        }
        return NO;
    }

    vm_address_t target = static_cast<vm_address_t>(page);
    vm_prot_t currentProtection = 0;
    vm_prot_t maximumProtection = 0;
    kern_return_t result = vm_remap(mach_task_self(),
                                    &target,
                                    static_cast<vm_size_t>(pageSize),
                                    0,
                                    VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                                    mach_task_self(),
                                    reinterpret_cast<vm_address_t>(copy),
                                    FALSE,
                                    &currentProtection,
                                    &maximumProtection,
                                    VM_INHERIT_NONE);
    if (result != KERN_SUCCESS) {
        munmap(copy, pageSize);
        if (error) {
            *error = WCRCodePatchError([NSString stringWithFormat:
                @"vm_remap 覆盖代码页失败（%d）", result]);
        }
        return NO;
    }

    munmap(copy, pageSize);
    sys_icache_invalidate(destination, length);
    return YES;
}
