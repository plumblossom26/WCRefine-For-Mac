#import "WCRMessageRepeat.h"

#import "WCRCodePatch.h"

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <libkern/OSCacheControl.h>

#import <atomic>
#import <cstdint>
#import <cstring>
#import <functional>
#import <map>
#import <memory>
#import <set>
#import <string>
#import <sys/mman.h>
#import <vector>

#include <cstdio>
#include <cstdlib>
#include <ctime>

// 270135（4.1.15.55）的聊天消息长按菜单。复读不伪造剪贴板动作，也不模拟
// 键盘：菜单构建前复制微信自己的 MessageData 快照，点击时交给微信原生
// 转发提交链，把原消息发回快照记录的当前会话。

extern "C" {

void *gWCRMessageRepeatTrampoline = nullptr;

void WCRMessageRepeatBuilderHook(void *menuObject, void *menu, uintptr_t fillNames);
void *WCRMessageRepeatClone(void *self);
void WCRMessageRepeatInvokeStub(void);
void WCRMessageRepeatOnInvoke(void *action);

}  // extern "C"

namespace {

constexpr uint64_t kBuildMenuOffset = 0xcf46ac;
constexpr uint64_t kAddMenuItemOffset = 0xcf4058;
constexpr uint64_t kMakeTitleOffset = 0x6ef8028;
constexpr uint64_t kActionVtableOffset = 0x9c31fa8;
constexpr uint64_t kTargetMallocOffset = 0x7140030;
constexpr uint64_t kTargetFreeOffset = 0x714000c;
constexpr uint64_t kQStringFreeOffset = 0x6ea14cc;
constexpr uint64_t kMessageCopyOffset = 0x395584;
constexpr uint64_t kMessageDestroyOffset = 0x396780;
constexpr uint64_t kAddRecipientOffset = 0x17b6c7c;
constexpr uint64_t kForwardMessageOffset = 0x187184c;
constexpr uint64_t kMenuStyleOffset = 0xa342748;
constexpr uint64_t kMenuItemCopyOffset = 0xcf5264;
constexpr uint64_t kMenuItemMoveOffset = 0xcf558c;
constexpr uint64_t kMenuItemDestroyOffset = 0x1fa03c;
constexpr uint64_t kMessageDataVtableOffset = 0x9eb6620;
constexpr uint32_t kForwardPrologue[4] = {0xd10643ff, 0xa9136ffc, 0xa91467fa, 0xa9155ff8};

// 运行时按构建取地址。270135 的数字就是上面的常量，测试仍核对那些字面量。
// 270351 的入口由两份 arm64 切片的唯一指令窗口对上，序言与 270135 相同。
struct RepeatSites {
    const char *build;
    uint64_t buildMenu;
    uint64_t addMenuItem;
    uint64_t makeTitle;
    uint64_t actionVtable;
    uint64_t actionClone;
    uint64_t actionInvoke;
    uint64_t targetMalloc;
    uint64_t targetFree;
    uint64_t qstringFree;
    uint64_t messageCopy;
    uint64_t messageDestroy;
    uint64_t addRecipient;
    uint64_t forwardMessage;
    uint64_t menuStyle;
    uint64_t menuItemCopy;
    uint64_t menuItemMove;
    uint64_t menuItemDestroy;
    uint64_t messageDataVtable;
};

static const RepeatSites kRepeatSites[] = {
    {
        "270135",
        kBuildMenuOffset,
        kAddMenuItemOffset,
        kMakeTitleOffset,
        kActionVtableOffset,
        0x6478dc,
        0x647a00,
        kTargetMallocOffset,
        kTargetFreeOffset,
        kQStringFreeOffset,
        kMessageCopyOffset,
        kMessageDestroyOffset,
        kAddRecipientOffset,
        kForwardMessageOffset,
        kMenuStyleOffset,
        kMenuItemCopyOffset,
        kMenuItemMoveOffset,
        kMenuItemDestroyOffset,
        kMessageDataVtableOffset,
    },
    {
        // 动作表 0x9d792f0 的 +0x10/+0x30 是 clone/invoke。
        // 分配跳板是 operator new / operator delete，间距仍是 0x24。
        // 消息虚表是复制函数里的符号地址 +0x10。
        "270351",
        0xd31de8,
        0xd3176c,
        0x7065338,
        0x9d792f0,
        0x64bdf0,
        0x64bf14,
        0x72acd48,
        0x72acd24,
        0x700e7dc,
        0x39769c,
        0x398890,
        0x180cb9c,
        0x18c8100,
        0xa493088,
        0xd329e0,
        0xd32d08,
        0x1fbae4,
        0xa002468,
    },
};

static const RepeatSites *gSites = nullptr;

static const RepeatSites *RepeatSitesFor(const char *build) {
    if (!build) return nullptr;
    for (const RepeatSites &sites : kRepeatSites) {
        if (strcmp(sites.build, build) == 0) return &sites;
    }
    return nullptr;
}

constexpr uint32_t kRepeatKey = 1001;
constexpr uint32_t kMenuFlags = 2;
// 原生转发 action（0x647a00）从 model+0x120 读取 MessageData：
// +0x128 type、+0x12c subtype、+0x1b0 source ID。
constexpr size_t kMessageDataOffset = 0x120;
constexpr size_t kMessageDataBytes = 0x350;
constexpr size_t kMessageTypeOffset = 0x8;
constexpr size_t kMessageSessionOffset = 0x58;
constexpr size_t kMessageSourceIDOffset = 0x90;
constexpr size_t kMenuItemStride = 0x190;
constexpr size_t kActionBytes = 0x20;
constexpr size_t kVtableBytes = 0x80;
constexpr size_t kTrampolineBytes = 32;
constexpr size_t kMenuStyleBytes = 0x100;
constexpr int kMaxMenuItems = 64;

static std::atomic_bool gInstalled(false);
static std::atomic_bool gEnabled(false);
static std::atomic_bool gInFlight(false);
static std::atomic<uintptr_t> gSlide(0);
static thread_local bool gInBuilderHook = false;

static uint8_t *gBuilderEntry = nullptr;
static uint8_t gSavedPrologue[16];
static void *gCallableVtable = nullptr;
static void *gTargetMalloc = nullptr;
static void *gTargetFree = nullptr;
static void *gQStringFree = nullptr;
static void *gMessageCopy = nullptr;
static void *gMessageDestroy = nullptr;
static void *gAddRecipient = nullptr;
static void *gForwardMessage = nullptr;
static void *gMenuItemCopy = nullptr;
static void *gMenuItemMove = nullptr;
static void *gMenuItemDestroy = nullptr;
static FILE *gLog = nullptr;

using AddMenuItemFn = void (*)(void *menuObject, uint32_t key, void **title,
                               int *flags, void *action, const void *style);
using MakeTitleFn = void *(*)(const char *text, int length);
using MallocFn = void *(*)(size_t size);
using FreeFn = void (*)(void *pointer);
using MessageCopyFn = void (*)(void *destination, const void *source);
using MessageDestroyFn = void (*)(void *message);
using AddRecipientFn = void (*)(void *targets, int32_t key, const std::string *recipient);

struct ForwardTargets {
    std::map<int32_t, std::set<std::string>> accounts;
    std::vector<std::shared_ptr<void>> additionalItems;
    std::string wxworkRecipient;
};

struct ForwardSubscription {
    uint64_t identifier;
    std::shared_ptr<void> cancellation;
    std::shared_ptr<void> owner;
};

// 异步转发任务会保存三个回调槽。全零代表空 std::function，工作线程若直接
// 调用就会跳到 0；保持显式 no-op 回调，既满足 ABI 又不产生副作用。
struct ForwardCallbacks {
    uintptr_t reserved[2] = {};
    std::function<void()> first;
    std::function<void()> second;
    std::function<void()> third;
};

using ForwardMessageFn = ForwardSubscription (*)(ForwardTargets *, const void *,
                                                  const uintptr_t *, const uintptr_t *);

static_assert(sizeof(ForwardTargets) == 0x48, "270135 forward target ABI mismatch");
static_assert(sizeof(ForwardSubscription) == 0x28, "270135 forward subscription ABI mismatch");
static_assert(sizeof(ForwardCallbacks) == 0x70, "270135 forward callback ABI mismatch");

static NSError *RepeatError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMac.MessageRepeat"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"消息复读错误"}];
}

static FILE *RepeatLog(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = [@"~/Library/Logs/WCRefine" stringByExpandingTildeInPath];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *path = [dir stringByAppendingPathComponent:@"message-repeat.log"];
        gLog = fopen(path.fileSystemRepresentation, "a");
        if (gLog) {
            const char *build = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String];
            fprintf(gLog, "=== message repeat session %ld build=%s ===\n",
                    (long)time(nullptr), build ? build : "?");
            fflush(gLog);
        }
    });
    return gLog;
}

static void LogLine(NSString *line) {
    if (FILE *log = RepeatLog()) {
        flockfile(log);
        fprintf(log, "%s\n", line.UTF8String ?: "?");
        fflush(log);
        funlockfile(log);
    }
}

static bool SafeRead(const void *address, void *out, size_t length) {
    if (!address || !out || length == 0) return false;
    vm_size_t read = 0;
    kern_return_t result = vm_read_overwrite(mach_task_self(),
                                             reinterpret_cast<vm_address_t>(address),
                                             static_cast<vm_size_t>(length),
                                             reinterpret_cast<vm_address_t>(out),
                                             &read);
    return result == KERN_SUCCESS && read == length;
}

static bool PlausiblePointer(uintptr_t value) {
    if (value < 0x100000000ULL) return false;
    if (value > 0x00007FFFFFFFFFFFULL) return false;
    return true;
}

static void ReleaseRefcounted(void *value) {
    if (!value) return;
    auto *ref = reinterpret_cast<std::atomic<int> *>(value);
    int current = ref->load(std::memory_order_acquire);
    if (current == -1) return;
    int previous = ref->fetch_sub(1, std::memory_order_acq_rel);
    if (previous == 0 || previous == 1) {
        if (gQStringFree) {
            reinterpret_cast<void (*)(void *)>(gQStringFree)(value);
        } else {
            std::free(value);
        }
    }
}

static uintptr_t CurrentWeChatSlide(void) {
    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const char *name = _dyld_get_image_name(index);
        if (name && strstr(name, "/Contents/Resources/wechat.dylib")) {
            return static_cast<uintptr_t>(_dyld_get_image_vmaddr_slide(index));
        }
    }
    return 0;
}

static bool VerifyEntry(uintptr_t slide, uint64_t offset, const uint32_t expected[4],
                        const char *name, NSError **error) {
    uint8_t actual[16] = {};
    if (!SafeRead(reinterpret_cast<const void *>(slide + offset), actual, sizeof(actual))) {
        if (error) *error = RepeatError([NSString stringWithFormat:@"无法读取%s", name]);
        return false;
    }
    uint8_t wanted[16] = {};
    for (int index = 0; index < 4; ++index) {
        memcpy(wanted + index * 4, &expected[index], 4);
    }
    if (memcmp(actual, wanted, sizeof(actual)) != 0) {
        NSMutableString *hex = [NSMutableString string];
        for (uint8_t byte : actual) [hex appendFormat:@"%02x", byte];
        if (error) {
            *error = RepeatError([NSString stringWithFormat:
                @"%s字节不匹配（当前 %@）", name, hex]);
        }
        return false;
    }
    return true;
}

/// MenuData 的 native copy/destroy pair. The storage itself must stay aligned
/// and uninitialized until MessageCopy runs.
struct RepeatPayload {
    std::string session;
    alignas(16) uint8_t message[kMessageDataBytes];
    uint32_t type = 0;
    uint64_t sourceID = 0;

    RepeatPayload(const void *source, std::string sourceSession)
        : session(std::move(sourceSession)) {
        memset(message, 0, sizeof(message));
        reinterpret_cast<MessageCopyFn>(gMessageCopy)(message, source);
    }

    ~RepeatPayload() {
        if (gMessageDestroy) reinterpret_cast<MessageDestroyFn>(gMessageDestroy)(message);
    }
};

static void CopyMenuItem(void *destination, const void *source);
static void MoveMenuItem(void *destination, void *source);
static void DestroyMenuItem(void *item);

/// The menu model stores 0x190-byte non-trivial items. This wrapper has the
/// same size and root layout; every operation is delegated to the host.
struct MenuItem {
    alignas(16) uint8_t storage[kMenuItemStride];

    MenuItem(const MenuItem &other) {
        CopyMenuItem(storage, other.storage);
    }
    MenuItem(MenuItem &&other) noexcept {
        MoveMenuItem(storage, other.storage);
    }
    ~MenuItem() {
        DestroyMenuItem(storage);
    }
    MenuItem &operator=(const MenuItem &) = delete;
    MenuItem &operator=(MenuItem &&) = delete;
};

static_assert(sizeof(MenuItem) == kMenuItemStride, "270135 menu item ABI mismatch");

static void CopyMenuItem(void *destination, const void *source) {
    if (gMenuItemCopy) reinterpret_cast<MessageCopyFn>(gMenuItemCopy)(destination, source);
}

static void MoveMenuItem(void *destination, void *source) {
    if (gMenuItemMove) reinterpret_cast<MessageCopyFn>(gMenuItemMove)(destination, source);
}

static void DestroyMenuItem(void *item) {
    if (gMenuItemDestroy) reinterpret_cast<MessageDestroyFn>(gMenuItemDestroy)(item);
}

static bool ReadSessionString(const void *message, std::string *session) {
    if (!message || !session) return false;
    uint8_t raw[24] = {};
    if (!SafeRead(reinterpret_cast<const uint8_t *>(message) + kMessageSessionOffset,
                  raw, sizeof(raw))) return false;

    const bool isLong = static_cast<int8_t>(raw[23]) < 0;
    size_t length = isLong ? *reinterpret_cast<size_t *>(raw + 8) : raw[23];
    const void *bytes = isLong ? *reinterpret_cast<void **>(raw) : raw;
    if (!bytes || length == 0 || length > 128) return false;

    char buffer[128] = {};
    if (!SafeRead(bytes, buffer, length)) return false;
    for (size_t index = 0; index < length; ++index) {
        const unsigned char ch = static_cast<unsigned char>(buffer[index]);
        if (ch < 0x21 || ch > 0x7e || ch == '<' || ch == '>' || ch == '"' || ch == '\\') {
            return false;
        }
    }
    session->assign(buffer, length);
    return !session->empty();
}

static bool ReadMessageHeader(void *menuObject, uint32_t *typeOut, uint64_t *sourceIDOut,
                              std::string *sessionOut) {
    if (!menuObject || !typeOut || !sourceIDOut || !sessionOut) return false;
    auto *source = reinterpret_cast<uint8_t *>(menuObject) + kMessageDataOffset;

    uintptr_t vtable = 0;
    if (!SafeRead(source, &vtable, sizeof(vtable)) || !PlausiblePointer(vtable)) {
        LogLine(@"header: message vtable unreadable");
        return false;
    }
    const uintptr_t expected = gSlide.load(std::memory_order_acquire) +
        (gSites ? gSites->messageDataVtable : 0);
    if (vtable != expected) {
        LogLine([NSString stringWithFormat:@"header: vtable mismatch actual=%p expected=%p",
                 reinterpret_cast<void *>(vtable), reinterpret_cast<void *>(expected)]);
        return false;
    }

    uint32_t type = 0;
    uint64_t sourceID = 0;
    if (!SafeRead(source + kMessageTypeOffset, &type, sizeof(type)) ||
        !SafeRead(source + kMessageSourceIDOffset, &sourceID, sizeof(sourceID))) {
        LogLine(@"header: type or source ID unreadable");
        return false;
    }
    if (type == 0 || type >= 10000 || sourceID == 0) {
        LogLine([NSString stringWithFormat:@"header: invalid type=%u sourceID=0x%llx",
                 type, (unsigned long long)sourceID]);
        return false;
    }
    if (!ReadSessionString(source, sessionOut)) {
        LogLine([NSString stringWithFormat:@"header: invalid session type=%u", type]);
        return false;
    }

    *typeOut = type;
    *sourceIDOut = sourceID;
    return true;
}

static bool MenuHasKey(const uint8_t *begin, uint64_t count, uint32_t key,
                       uint8_t **itemOut) {
    for (uint64_t index = 0; index < count; ++index) {
        uint8_t *item = const_cast<uint8_t *>(begin + index * kMenuItemStride);
        uint32_t candidate = 0;
        if (!SafeRead(item, &candidate, sizeof(candidate))) return false;
        if (candidate == key) {
            if (itemOut) *itemOut = item;
            return true;
        }
    }
    return false;
}

static bool SetupCallableVtable(uintptr_t slide, NSError **error) {
    if (gCallableVtable) return true;

    uint8_t original[kVtableBytes] = {};
    const void *source = reinterpret_cast<const void *>(slide + gSites->actionVtable);
    if (!SafeRead(source, original, sizeof(original))) {
        if (error) *error = RepeatError(@"复读菜单动作表不可读");
        return false;
    }

    void *copy = mmap(nullptr, kVtableBytes, PROT_READ | PROT_WRITE,
                      MAP_ANON | MAP_PRIVATE, -1, 0);
    if (copy == MAP_FAILED) {
        if (error) *error = RepeatError(@"无法分配复读动作表");
        return false;
    }
    memcpy(copy, original, sizeof(original));

    uintptr_t originalClone = 0;
    uintptr_t originalInvoke = 0;
    memcpy(&originalClone, original + 0x10, sizeof(originalClone));
    memcpy(&originalInvoke, original + 0x30, sizeof(originalInvoke));
    if (!gSites || originalClone != slide + gSites->actionClone ||
        originalInvoke != slide + gSites->actionInvoke) {
        munmap(copy, kVtableBytes);
        if (error) *error = RepeatError(@"复读动作表布局不匹配");
        return false;
    }

    uintptr_t clone = reinterpret_cast<uintptr_t>(&WCRMessageRepeatClone);
    uintptr_t invoke = reinterpret_cast<uintptr_t>(&WCRMessageRepeatInvokeStub);
    memcpy(reinterpret_cast<uint8_t *>(copy) + 0x10, &clone, sizeof(clone));
    memcpy(reinterpret_cast<uint8_t *>(copy) + 0x30, &invoke, sizeof(invoke));
    sys_icache_invalidate(copy, kVtableBytes);
    if (mprotect(copy, kVtableBytes, PROT_READ) != 0) {
        munmap(copy, kVtableBytes);
        if (error) *error = RepeatError(@"无法锁定复读动作表");
        return false;
    }

    gCallableVtable = copy;
    return true;
}

static void *CreateAction(void *menuObject, std::shared_ptr<RepeatPayload> payload) {
    if (!gTargetMalloc || !gCallableVtable || !payload) return nullptr;
    alignas(16) uint8_t *action = static_cast<uint8_t *>(
        reinterpret_cast<MallocFn>(gTargetMalloc)(kActionBytes));
    if (!action) return nullptr;
    memset(action, 0, kActionBytes);

    struct SharedPtrWords {
        void *object;
        void *control;
    };
    static_assert(sizeof(std::shared_ptr<RepeatPayload>) == sizeof(SharedPtrWords));
    SharedPtrWords words = {};
    memcpy(&words, &payload, sizeof(words));

    uintptr_t vtable = reinterpret_cast<uintptr_t>(gCallableVtable);
    uintptr_t self = reinterpret_cast<uintptr_t>(menuObject);
    memcpy(action + 0, &vtable, sizeof(vtable));
    memcpy(action + 8, &self, sizeof(self));
    memcpy(action + 0x10, &words.object, sizeof(words.object));
    memcpy(action + 0x18, &words.control, sizeof(words.control));
    if (words.control) {
        auto *owners = reinterpret_cast<std::atomic<uint64_t> *>(
            static_cast<uint8_t *>(words.control) + 8);
        owners->fetch_add(1, std::memory_order_relaxed);
    }
    return action;
}

static void DeleteAction(void *action) {
    if (!action || !gCallableVtable) return;
    uintptr_t deletingDestructor = 0;
    memcpy(&deletingDestructor, static_cast<uint8_t *>(gCallableVtable) + 0x28,
           sizeof(deletingDestructor));
    if (deletingDestructor) {
        reinterpret_cast<void (*)(void *)>(deletingDestructor)(action);
    } else if (gTargetFree) {
        reinterpret_cast<FreeFn>(gTargetFree)(action);
    }
}

static bool ReorderNativeItems(void *menuObject) {
    auto *vector = reinterpret_cast<std::vector<MenuItem> *>(
        static_cast<uint8_t *>(menuObject) + 8);
    if (!vector || vector->size() < 2 ||
        vector->size() > static_cast<size_t>(kMaxMenuItems)) {
        return false;
    }

    uint32_t lastKey = 0;
    if (!SafeRead(&vector->back(), &lastKey, sizeof(lastKey)) || lastKey != kRepeatKey) {
        return false;
    }

    // Move the freshly appended item first, then preserve the host order of all
    // pre-existing items. The temporary vector destroys only moved-from hosts.
    std::vector<MenuItem> ordered;
    ordered.reserve(vector->size());
    ordered.emplace_back(std::move(vector->back()));
    for (size_t index = 0; index + 1 < vector->size(); ++index) {
        ordered.emplace_back(std::move((*vector)[index]));
    }
    vector->swap(ordered);
    return true;
}

static void AppendRepeatItem(void *menuObject) {
    auto *base = reinterpret_cast<uint8_t *>(menuObject);
    uintptr_t begin = 0;
    uintptr_t end = 0;
    if (!SafeRead(base + 8, &begin, sizeof(begin)) ||
        !SafeRead(base + 16, &end, sizeof(end)) ||
        !PlausiblePointer(begin) || end <= begin) {
        return;
    }
    const uint64_t span = end - begin;
    if (span % kMenuItemStride != 0) return;
    const uint64_t count = span / kMenuItemStride;
    if (count == 0 || count > static_cast<uint64_t>(kMaxMenuItems)) return;
    if (MenuHasKey(reinterpret_cast<const uint8_t *>(begin), count, kRepeatKey, nullptr)) return;

    uint32_t type = 0;
    uint64_t sourceID = 0;
    std::string session;
    if (!ReadMessageHeader(menuObject, &type, &sourceID, &session)) {
        LogLine(@"append: message header not recognized");
        return;
    }

    try {
        auto payload = std::make_shared<RepeatPayload>(
            static_cast<uint8_t *>(menuObject) + kMessageDataOffset, std::move(session));
        payload->type = type;
        payload->sourceID = sourceID;

        void *action = CreateAction(menuObject, payload);
        if (!action) {
            LogLine(@"append: action allocation failed");
            return;
        }

        static const char titleBytes[] = "复读";
        void *title = reinterpret_cast<MakeTitleFn>(gSlide.load() + gSites->makeTitle)(
            titleBytes, -1);
        if (!title) {
            DeleteAction(action);
            LogLine(@"append: title factory returned null");
            return;
        }

        uint8_t style[kMenuStyleBytes] = {};
        if (!gSites ||
            !SafeRead(reinterpret_cast<const void *>(gSlide.load() + gSites->menuStyle),
                      style, sizeof(style))) {
            ReleaseRefcounted(title);
            DeleteAction(action);
            LogLine(@"append: menu style unreadable");
            return;
        }

        alignas(16) uint8_t holder[0x20] = {};
        const uintptr_t actionAddress = reinterpret_cast<uintptr_t>(action);
        memcpy(holder + 0x18, &actionAddress, sizeof(actionAddress));

        int flags = kMenuFlags;
        reinterpret_cast<AddMenuItemFn>(gSlide.load() + gSites->addMenuItem)(
            menuObject, kRepeatKey, &title, &flags, holder, style);
        ReleaseRefcounted(title);
        DeleteAction(action);

        uintptr_t updatedBegin = 0;
        uintptr_t updatedEnd = 0;
        if (!SafeRead(base + 8, &updatedBegin, sizeof(updatedBegin)) ||
            !SafeRead(base + 16, &updatedEnd, sizeof(updatedEnd)) ||
            updatedEnd <= updatedBegin ||
            (updatedEnd - updatedBegin) % kMenuItemStride != 0) {
            LogLine(@"append: native menu bounds became invalid");
            return;
        }
        const uint64_t updatedCount = (updatedEnd - updatedBegin) / kMenuItemStride;
        if (updatedCount == 0 || updatedCount > static_cast<uint64_t>(kMaxMenuItems)) {
            LogLine(@"append: native menu count became invalid");
            return;
        }
        uint8_t *reordered = nullptr;
        if (!MenuHasKey(reinterpret_cast<const uint8_t *>(updatedBegin), updatedCount,
                        kRepeatKey, &reordered)) {
            LogLine(@"append: native item was rejected");
            return;
        }
        if (!ReorderNativeItems(menuObject)) {
            reinterpret_cast<std::vector<MenuItem> *>(base + 8)->pop_back();
            LogLine(@"append: repeat item removed because it could not be moved to top");
            return;
        }
        LogLine([NSString stringWithFormat:@"append: repeat item added type=%u", type]);
    } catch (...) {
        LogLine(@"append: native allocation or snapshot failed");
    }
}

static bool SubmitMessage(RepeatPayload *payload) {
    if (!payload || !gAddRecipient || !gForwardMessage || payload->type == 0 ||
        payload->sourceID == 0 || payload->session.empty()) {
        return false;
    }
    const uintptr_t slide = gSlide.load(std::memory_order_acquire);
    if (!slide || !gSites ||
        !VerifyEntry(slide, gSites->forwardMessage, kForwardPrologue,
                               "复读原生转发", nil)) {
        LogLine(@"invoke: native forward entry changed; skipped");
        return false;
    }
    try {
        ForwardTargets targets;
        std::string recipient = payload->session;
        reinterpret_cast<AddRecipientFn>(gAddRecipient)(&targets, 2, &recipient);

        const auto found = targets.accounts.find(2);
        if (targets.accounts.size() != 1 || found == targets.accounts.end() ||
            found->second.size() != 1 || *found->second.begin() != recipient ||
            !targets.additionalItems.empty() || !targets.wxworkRecipient.empty()) {
            LogLine(@"invoke: target validation failed");
            return false;
        }

        uintptr_t source[16] = {};
        ForwardCallbacks callbacks;
        auto noop = [] {};
        callbacks.first = noop;
        callbacks.second = noop;
        callbacks.third = noop;
        ForwardSubscription subscription = reinterpret_cast<ForwardMessageFn>(gForwardMessage)(
            &targets,
            payload->message,
            source,
            reinterpret_cast<const uintptr_t *>(&callbacks));
        const bool submitted = subscription.identifier != 0 && subscription.cancellation != nullptr;
        LogLine([NSString stringWithFormat:
            @"invoke: native forward submitted=%d type=%u", submitted ? 1 : 0, payload->type]);
        return submitted;
    } catch (...) {
        LogLine(@"invoke: native forward threw");
        return false;
    }
}

}  // namespace

extern "C" void *WCRMessageRepeatClone(void *self) {
    if (!self || !gTargetMalloc) return nullptr;
    auto *source = static_cast<uint8_t *>(self);
    auto *copy = static_cast<uint8_t *>(reinterpret_cast<MallocFn>(gTargetMalloc)(kActionBytes));
    if (!copy) return nullptr;
    memcpy(copy, source, kActionBytes);
    uintptr_t vtable = reinterpret_cast<uintptr_t>(gCallableVtable);
    memcpy(copy, &vtable, sizeof(vtable));

    void *control = nullptr;
    memcpy(&control, copy + 0x18, sizeof(control));
    if (control) {
        auto *owners = reinterpret_cast<std::atomic<uint64_t> *>(
            static_cast<uint8_t *>(control) + 8);
        owners->fetch_add(1, std::memory_order_relaxed);
    }
    return copy;
}

extern "C" void WCRMessageRepeatBuilderHook(void *menuObject, void *menu, uintptr_t fillNames) {
    (void)menu;
    if (!gEnabled.load(std::memory_order_acquire) || !menuObject || fillNames != 1) return;
    if (gInBuilderHook) return;
    gInBuilderHook = true;
    @try {
        AppendRepeatItem(menuObject);
    } @catch (NSException *exception) {
        LogLine([NSString stringWithFormat:@"append: exception %@", exception.reason ?: @"unknown"]);
    } @catch (...) {
        LogLine(@"append: unknown exception");
    }
    gInBuilderHook = false;
}

/// 微信菜单入口：保留参数寄存器，先追加菜单项，再跳回原函数第 4 条指令后。
__attribute__((naked)) extern "C" void WCRMessageRepeatBuilderStub(void) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-128]!\n"
        "stp x0, x1, [sp, #16]\n"
        "stp x2, x3, [sp, #32]\n"
        "stp x4, x5, [sp, #48]\n"
        "stp x6, x7, [sp, #64]\n"
        "str x8, [sp, #80]\n"
        "bl _WCRMessageRepeatBuilderHook\n"
        "ldp x0, x1, [sp, #16]\n"
        "ldp x2, x3, [sp, #32]\n"
        "ldp x4, x5, [sp, #48]\n"
        "ldp x6, x7, [sp, #64]\n"
        "ldr x8, [sp, #80]\n"
        "ldp x29, x30, [sp], #128\n"
        "adrp x16, _gWCRMessageRepeatTrampoline@PAGE\n"
        "ldr x16, [x16, _gWCRMessageRepeatTrampoline@PAGEOFF]\n"
        "br x16\n");
}

extern "C" void WCRMessageRepeatOnInvoke(void *action) {
    if (!gEnabled.load(std::memory_order_acquire) || !gInstalled.load() || !action) return;
    if (![NSThread isMainThread]) {
        LogLine(@"invoke: ignored off-main-thread click");
        return;
    }
    if (gInFlight.exchange(true)) return;
    void *payload = nullptr;
    memcpy(&payload, static_cast<uint8_t *>(action) + 0x10, sizeof(payload));
    if (!payload) {
        gInFlight.store(false);
        return;
    }
    @try {
        SubmitMessage(static_cast<RepeatPayload *>(payload));
    } @catch (NSException *exception) {
        LogLine([NSString stringWithFormat:@"invoke: exception %@", exception.reason ?: @"unknown"]);
    } @catch (...) {
        LogLine(@"invoke: unknown exception");
    }
    gInFlight.store(false);
}

/// 自定义 action 的调用槽。x0 是 action 对象，转发完成后直接返回。
__attribute__((naked)) extern "C" void WCRMessageRepeatInvokeStub(void) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-16]!\n"
        "bl _WCRMessageRepeatOnInvoke\n"
        "ldp x29, x30, [sp], #16\n"
        "ret\n");
}

BOOL WCRMessageRepeatSupportsProfile(const WCRPatchProfile *profile) {
    return profile && profile->repeatMenuBuilderAddress != 0 &&
           RepeatSitesFor(profile->buildVersion) != nullptr;
}

BOOL WCRMessageRepeatInstall(const WCRPatchProfile *profile, NSError **error) {
    if (gInstalled.load()) return YES;
    if (!WCRMessageRepeatSupportsProfile(profile)) {
        if (error) *error = RepeatError(@"当前微信构建没有复读所需的入口");
        return NO;
    }
    gSites = RepeatSitesFor(profile->buildVersion);

    uintptr_t slide = CurrentWeChatSlide();
    if (!slide) {
        if (error) *error = RepeatError(@"wechat.dylib 尚未加载");
        return NO;
    }

    auto *entry = reinterpret_cast<uint8_t *>(slide + gSites->buildMenu);
    uint8_t current[16] = {};
    if (!SafeRead(entry, current, sizeof(current))) {
        if (error) *error = RepeatError(@"无法读取复读菜单入口");
        return NO;
    }
    if (memcmp(current, profile->repeatMenuBuilderPrologue, sizeof(current)) != 0) {
        NSMutableString *actual = [NSMutableString string];
        for (uint8_t byte : current) [actual appendFormat:@"%02x", byte];
        LogLine([NSString stringWithFormat:@"install: prologue mismatch %@", actual]);
        if (error) *error = RepeatError([NSString stringWithFormat:
            @"复读菜单入口字节不匹配（当前 %@）", actual]);
        return NO;
    }

    static const uint32_t menuPrologue[4] = {0xa9bb67fa, 0xa9015ff8, 0xa90257f6, 0xa9034ff4};
    static const uint32_t titlePrologue[4] = {0xd100c3ff, 0xa9014ff4, 0xa9027bfd, 0x910083fd};
    static const uint32_t messageCopyPrologue[4] = {0xa9bd57f6, 0xa9014ff4, 0xa9027bfd, 0x910083fd};
    static const uint32_t messageDestroyPrologue[4] = {0xa9be4ff4, 0xa9017bfd, 0x910043fd, 0xaa0003f3};
    static const uint32_t addRecipientPrologue[4] = {0xd10183ff, 0xa9025ff8, 0xa90357f6, 0xa9044ff4};
    // 0xcf5264 复制 0x190 字节菜单项，序言与 0xcf4058 相同；不能套用
    // 附近 vector 搬运函数的较短序言。
    static const uint32_t itemCopyPrologue[4] = {0xa9bb67fa, 0xa9015ff8, 0xa90257f6, 0xa9034ff4};
    static const uint32_t itemMovePrologue[4] = {0xa9bd57f6, 0xa9014ff4, 0xa9027bfd, 0x910083fd};
    static const uint32_t itemDestroyPrologue[4] = {0xa9be4ff4, 0xa9017bfd, 0x910043fd, 0xaa0003f3};

    if (!VerifyEntry(slide, gSites->addMenuItem, menuPrologue, "复读添加菜单项", error) ||
        !VerifyEntry(slide, gSites->makeTitle, titlePrologue, "复读标题构造", error) ||
        !VerifyEntry(slide, gSites->messageCopy, messageCopyPrologue, "复读消息快照", error) ||
        !VerifyEntry(slide, gSites->messageDestroy, messageDestroyPrologue, "复读消息快照析构", error) ||
        !VerifyEntry(slide, gSites->addRecipient, addRecipientPrologue, "复读目标插入", error) ||
        !VerifyEntry(slide, gSites->forwardMessage, kForwardPrologue, "复读原生转发", error) ||
        !VerifyEntry(slide, gSites->menuItemCopy, itemCopyPrologue, "复读菜单项复制", error) ||
        !VerifyEntry(slide, gSites->menuItemMove, itemMovePrologue, "复读菜单项移动", error) ||
        !VerifyEntry(slide, gSites->menuItemDestroy, itemDestroyPrologue, "复读菜单项析构", error)) {
        return NO;
    }

    NSError *vtableError = nil;
    if (!SetupCallableVtable(slide, &vtableError)) {
        if (error) *error = vtableError;
        return NO;
    }

    void *trampoline = mmap(nullptr, kTrampolineBytes, PROT_READ | PROT_WRITE,
                            MAP_ANON | MAP_PRIVATE, -1, 0);
    if (trampoline == MAP_FAILED) {
        if (error) *error = RepeatError(@"无法分配复读跳板");
        return NO;
    }
    auto *bytes = static_cast<uint8_t *>(trampoline);
    memcpy(bytes, current, 16);
    uint32_t tail[2] = {0x58000050u, 0xD61F0200u};  // ldr x16,#8; br x16
    memcpy(bytes + 16, tail, sizeof(tail));
    uint64_t continueAddress = reinterpret_cast<uint64_t>(entry) + 16;
    memcpy(bytes + 24, &continueAddress, sizeof(continueAddress));
    sys_icache_invalidate(bytes, kTrampolineBytes);
    if (mprotect(trampoline, kTrampolineBytes, PROT_READ | PROT_EXEC) != 0) {
        munmap(trampoline, kTrampolineBytes);
        if (error) *error = RepeatError(@"无法将复读跳板设为可执行");
        return NO;
    }

    uint8_t patch[16] = {};
    memcpy(patch, tail, sizeof(tail));
    uint64_t hookAddress = reinterpret_cast<uint64_t>(&WCRMessageRepeatBuilderStub);
    memcpy(patch + 8, &hookAddress, sizeof(hookAddress));

    gSlide.store(slide);
    gTargetMalloc = reinterpret_cast<void *>(slide + gSites->targetMalloc);
    gTargetFree = reinterpret_cast<void *>(slide + gSites->targetFree);
    gQStringFree = reinterpret_cast<void *>(slide + gSites->qstringFree);
    gMessageCopy = reinterpret_cast<void *>(slide + gSites->messageCopy);
    gMessageDestroy = reinterpret_cast<void *>(slide + gSites->messageDestroy);
    gAddRecipient = reinterpret_cast<void *>(slide + gSites->addRecipient);
    gForwardMessage = reinterpret_cast<void *>(slide + gSites->forwardMessage);
    gMenuItemCopy = reinterpret_cast<void *>(slide + gSites->menuItemCopy);
    gMenuItemMove = reinterpret_cast<void *>(slide + gSites->menuItemMove);
    gMenuItemDestroy = reinterpret_cast<void *>(slide + gSites->menuItemDestroy);
    gWCRMessageRepeatTrampoline = trampoline;

    NSError *patchError = nil;
    if (!WCRPatchCodeBytes(entry, patch, sizeof(patch), &patchError)) {
        gWCRMessageRepeatTrampoline = nullptr;
        gSlide.store(0);
        munmap(trampoline, kTrampolineBytes);
        if (error) *error = patchError;
        return NO;
    }

    memcpy(gSavedPrologue, current, sizeof(current));
    gBuilderEntry = entry;
    gEnabled.store(true);
    gInstalled.store(true);
    LogLine([NSString stringWithFormat:@"install: ok entry=%p slide=0x%llx",
             entry, (unsigned long long)slide]);
    return YES;
}

BOOL WCRMessageRepeatUninstall(NSError **error) {
    gEnabled.store(false);
    if (!gInstalled.load()) return YES;

    NSError *patchError = nil;
    if (gBuilderEntry &&
        !WCRPatchCodeBytes(gBuilderEntry, gSavedPrologue, sizeof(gSavedPrologue), &patchError)) {
        if (error) *error = patchError;
        return NO;
    }
    if (gWCRMessageRepeatTrampoline) {
        mprotect(gWCRMessageRepeatTrampoline, kTrampolineBytes, PROT_READ | PROT_WRITE);
        munmap(gWCRMessageRepeatTrampoline, kTrampolineBytes);
        gWCRMessageRepeatTrampoline = nullptr;
    }
    gBuilderEntry = nullptr;
    gSlide.store(0);
    gInstalled.store(false);
    LogLine(@"uninstall: ok");
    return YES;
}

BOOL WCRMessageRepeatIsInstalled(void) {
    return gInstalled.load();
}
