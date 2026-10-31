#import "WCRRecallNotify.h"

#import "WCROriginalID.h"
#import "WCRContactName.h"

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>

#include <atomic>
#include <cstdint>
#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <regex>
#include <set>
#include <string>
#include <type_traits>
#include <vector>

// 270135 的撤回通知发送链。序言和偏移必须与 WCRMessageRepeat 里同一批函数一致。
// wrap→MessageData 的函数起点是 0x4cbfc30，按 ARM64 大结构体约定用 x8 返回
// 0x350 字节的 MessageData。0x4cbfc40 是序言第 5 条（STP X29,X30），从那里
// 进入会跳过 SUB SP 和 callee-saved 入栈，最终跳到 0。
// 登录期 wrap 的扩展全局 A51F728/A51F710 可能仍是空指针，转换前必须核对
// wrap 虚表、vtable+40 和这两个全局。通知文字外壳仍本地构造，不走转换。
// 转发给自己走微信原生 forward，源 ID 必须是 0。带上原服务器 ID 时，微信
// 会把已经撤回的那条当成系统消息转出，会话里刚写好的灰色系统提示也会被盖掉。

namespace {

constexpr uint64_t kMessageCopyOffset = 0x395584;
constexpr uint64_t kMessageDestroyOffset = 0x396780;
constexpr uint64_t kAddRecipientOffset = 0x17b6c7c;
constexpr uint64_t kForwardMessageOffset = 0x187184c;
constexpr uint64_t kConvertOffset = 0x4cbfc30;
constexpr uint64_t kMessageDataVtableOffset = 0x9eb6620;
constexpr uint64_t kWrapVtableOffset = 0x9eb04f0;
constexpr uint64_t kExtGlobalAOffset = 0xA51F728;
constexpr uint64_t kExtGlobalBOffset = 0xA51F710;
// 0x4669774 直接读取这个全局服务；未登录或界面服务尚未建好时它是空指针，
// 转发函数随后会解引用空对象。调用前必须自己检查，SIGSEGV 不能用 catch 拦。
constexpr uint64_t kForwardServiceGlobalOffset = 0xA45DF38;

constexpr size_t kMessageDataBytes = 0x350;
constexpr size_t kMessageTypeOffset = 0x8;
constexpr size_t kMessageBodyOffset = 0xB8;
constexpr size_t kMessageSourceIDOffset = 0x90;
constexpr size_t kWrapTypeOffset = 0x0C;
constexpr size_t kWrapServerIDOffset = 0xF8;
constexpr size_t kMaxSnapshots = 48;
constexpr size_t kMaxTemplateBytes = 1000;
constexpr size_t kMaxNoticeBytes = 4000;

// 0x395584 会深拷贝的 std::string。+0xB0 是裸 qword，不是正文。
constexpr size_t kStringOffsets[] = {
    0x10, 0x28, 0x40, 0x58, 0x78, kMessageBodyOffset, 0xD0, 0x108, 0x120,
    0x140, 0x158, 0x170, 0x188, 0x1A0, 0x1B8, 0x1E0, 0x1F8, 0x248, 0x260,
    0x278, 0x290, 0x2A8, 0x2C0, 0x2D8,
};

constexpr uint32_t kCopyPrologue[4] = {0xa9bd57f6, 0xa9014ff4, 0xa9027bfd, 0x910083fd};
constexpr uint32_t kDestroyPrologue[4] = {0xa9be4ff4, 0xa9017bfd, 0x910043fd, 0xaa0003f3};
constexpr uint32_t kAddRecipientPrologue[4] = {0xd10183ff, 0xa9025ff8, 0xa90357f6, 0xa9044ff4};
constexpr uint32_t kForwardPrologue[4] = {0xd10643ff, 0xa9136ffc, 0xa91467fa, 0xa9155ff8};
constexpr uint32_t kConvertPrologue[4] = {0xd101c3ff, 0xa9035ff8, 0xa90457f6, 0xa9054ff4};

struct WrapNestedSlot {
    size_t wrapOffset;
    size_t fallbackOffset;
    size_t readableBytes;
};

// readableBytes 按 sub_4CBFC30 对该槽位的最远字段，而不是一律 64：
// 496/504 这类扩展块只有十几个字节，64 字节探测会把可转的 wrap 误判掉。
constexpr WrapNestedSlot kWrapNested[] = {
    {416, 16, 32}, {424, 24, 56}, {432, 32, 24}, {440, 40, 48}, {448, 48, 24},
    {456, 56, 56}, {464, 64, 16}, {488, 88, 40}, {496, 96, 16}, {504, 104, 16},
};

constexpr uint32_t kSnapshotTypes[] = {1, 3, 34, 42, 43, 47, 48, 49};

static NSString *const kMasterKey = @"WCRefineMacRecallNotifyEnabled";
static NSString *const kSelfKey = @"WCRefineMacRecallNotifySelf";
static NSString *const kSessionKey = @"WCRefineMacRecallNotifySession";
static NSString *const kForwardKey = @"WCRefineMacRecallNotifyForwardSelf";
static NSString *const kTargetSessionKey = @"WCRefineMacRecallNotifyTargetSession";
static NSString *const kTemplateKey = @"WCRefineMacRecallNoticeTemplate";
static NSString *const kLeaveSessionKey = @"WCRefineMacGroupLeaveNotifySession";
static NSString *const kLeaveSelfKey = @"WCRefineMacGroupLeaveNotifySelf";

using MessageCopyFn = void (*)(void *destination, const void *source);
using MessageDestroyFn = void (*)(void *message);
using AddRecipientFn = void (*)(void *targets, int32_t key, const std::string *recipient);

struct alignas(16) ConvertedMessage {
    uint8_t bytes[kMessageDataBytes];
};
using ConvertFn = ConvertedMessage (*)(const void *wrap);
static_assert(std::is_trivial_v<ConvertedMessage>,
              "ConvertedMessage must stay POD so clang returns it in x8");

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

// 微信的转发订阅对象固定带三个回调槽。空 std::function 在同步提交时会被
// 当成“没有回调”，但异步工作线程仍可能直接调用槽位，最终跳到地址 0。
// 三个 no-op 回调保持槽位有效，又不改变发送行为。
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
static_assert(kMessageBodyOffset != 0xB0, "notice body must not use the 269079 content slot");

std::mutex gMutex;
std::atomic_bool gReady{false};
std::atomic<uintptr_t> gSlide{0};
std::atomic<uintptr_t> gCopy{0};
std::atomic<uintptr_t> gDestroy{0};
std::atomic<uintptr_t> gAddRecipient{0};
std::atomic<uintptr_t> gForward{0};
std::atomic<uintptr_t> gConvert{0};
std::atomic_bool gMaster{false};
std::atomic_bool gNotifySelf{true};
std::atomic_bool gNotifySession{false};
std::atomic_bool gForwardSelf{false};
std::atomic_bool gLeaveNotifySession{false};
std::atomic_bool gLeaveNotifySelf{false};
std::atomic_bool gLeaveMonitorActive{false};

struct OwnedMessage {
    alignas(16) uint8_t bytes[kMessageDataBytes];
    bool live = false;

    OwnedMessage() { memset(bytes, 0, sizeof(bytes)); }
    OwnedMessage(const OwnedMessage &) = delete;
    OwnedMessage &operator=(const OwnedMessage &) = delete;
    ~OwnedMessage() { clear(); }

    void clear() {
        if (!live) return;
        auto destroy = reinterpret_cast<MessageDestroyFn>(gDestroy.load(std::memory_order_acquire));
        live = false;
        if (destroy) destroy(bytes);
    }

    bool adoptCopy(const void *source) {
        auto copy = reinterpret_cast<MessageCopyFn>(gCopy.load(std::memory_order_acquire));
        if (!copy || !source) return false;
        clear();
        memset(bytes, 0, sizeof(bytes));
        copy(bytes, source);
        live = true;
        return true;
    }
};

std::unique_ptr<OwnedMessage> gShell;
std::map<uint64_t, std::unique_ptr<OwnedMessage>> gSnapshots;
std::map<uint64_t, uint32_t> gSnapshotTypes;

os_log_t NotifyLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.wcrefine.mac", "recall-notify");
    });
    return log;
}

void Log(const char *message) {
    os_log_info(NotifyLog(), "%{public}s", message ? message : "");
}

NSError *NotifyError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMac.RecallNotify"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"撤回通知错误"}];
}

bool SafeRead(const void *address, void *out, size_t length) {
    if (!address || !out || length == 0) return false;
    vm_size_t read = 0;
    kern_return_t result = vm_read_overwrite(mach_task_self(),
                                             reinterpret_cast<vm_address_t>(address),
                                             static_cast<vm_size_t>(length),
                                             reinterpret_cast<vm_address_t>(out),
                                             &read);
    return result == KERN_SUCCESS && read == length;
}

bool ReadLibcppStringAt(const void *object, size_t offset, std::string &out,
                        size_t maxBytes = 4096) {
    if (!object) return false;
    uint8_t raw[24] = {};
    if (!SafeRead(reinterpret_cast<const uint8_t *>(object) + offset, raw, sizeof(raw))) {
        return false;
    }
    const int8_t flag = static_cast<int8_t>(raw[23]);
    if (flag >= 0) {
        size_t length = static_cast<uint8_t>(flag) & 0x7F;
        if (length > 22) return false;
        out.assign(reinterpret_cast<const char *>(raw), length);
        return true;
    }

    const char *data = nullptr;
    uint64_t rawLength = 0;
    memcpy(&data, raw, sizeof(data));
    memcpy(&rawLength, raw + 8, sizeof(rawLength));
    size_t length = static_cast<size_t>(rawLength & 0x7FFFFFFFFFFFFFFFULL);
    if (!data || length == 0 || length > maxBytes) return false;
    char buffer[4096];
    if (!SafeRead(data, buffer, length)) return false;
    out.assign(buffer, length);
    return true;
}

uintptr_t CurrentWeChatSlide(void) {
    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const char *name = _dyld_get_image_name(index);
        if (name && strstr(name, "/Contents/Resources/wechat.dylib")) {
            return static_cast<uintptr_t>(_dyld_get_image_vmaddr_slide(index));
        }
    }
    return 0;
}

bool VerifyEntry(uintptr_t slide, uint64_t offset, const uint32_t expected[4],
                 NSString *name, NSError **error) {
    uint8_t actual[16] = {};
    if (!SafeRead(reinterpret_cast<const void *>(slide + offset), actual, sizeof(actual))) {
        if (error) *error = NotifyError([NSString stringWithFormat:@"无法读取%@", name]);
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
            *error = NotifyError([NSString stringWithFormat:@"%@字节不匹配（当前 %@）", name, hex]);
        }
        return false;
    }
    return true;
}

BOOL ReadBool(NSString *key, BOOL fallback) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return stored ? [stored boolValue] : fallback;
}

void RefreshFlags(void) {
    gMaster.store(ReadBool(kMasterKey, NO), std::memory_order_release);
    gNotifySelf.store(ReadBool(kSelfKey, YES), std::memory_order_release);
    gNotifySession.store(ReadBool(kSessionKey, NO), std::memory_order_release);
    gForwardSelf.store(ReadBool(kForwardKey, NO), std::memory_order_release);
    gLeaveNotifySession.store(ReadBool(kLeaveSessionKey, NO), std::memory_order_release);
    gLeaveNotifySelf.store(ReadBool(kLeaveSelfKey, NO), std::memory_order_release);
}

std::string UTF8(NSString *value) {
    const char *raw = value.UTF8String;
    return raw ? std::string(raw) : std::string();
}

bool RecipientAllowed(const std::string &value) {
    if (value.empty() || value == "filehelper") return false;
    static const std::regex pattern("^(?:[A-Za-z0-9_\\-]{5,128}|[0-9]+@chatroom)$");
    return std::regex_match(value, pattern);
}

bool SnapshotType(uint32_t type) {
    for (uint32_t candidate : kSnapshotTypes) {
        if (candidate == type) return true;
    }
    return false;
}

// 只允许把普通聊天正文转发出去。撤回系统消息、灰字提示和通知文案都不能走这条转发。
bool IsNormalForwardBody(const std::string &body) {
    if (body.empty() || body.size() > kMaxNoticeBytes) return false;
    if (body.find("\xE2\x80\x8B") != std::string::npos) return false;
    if (body.find("已拦截一条撤回消息") != std::string::npos) return false;
    if (body.find("撤回了一条消息") != std::string::npos) return false;
    if (body.find("recalled a message") != std::string::npos) return false;
    if (body.find("<sysmsg") != std::string::npos) return false;
    if (body.find("<revokemsg") != std::string::npos) return false;
    if (body.find("type=\"revokemsg\"") != std::string::npos) return false;
    if (body.find("type='revokemsg'") != std::string::npos) return false;
    return true;
}

NSString *RenderNotice(NSString *templateString, NSString *name, NSString *timeText,
                       NSString *content, NSString *wxid, NSString *session) {
    NSString *tpl = templateString.length ? templateString : WCRRecallNotifyDefaultTemplate();
    NSString *contentValue = content ?: @"";
    if (contentValue.length == 0) {
        NSMutableArray<NSString *> *kept = [NSMutableArray array];
        for (NSString *line in [tpl componentsSeparatedByString:@"\n"]) {
            if ([line containsString:@"{content}"]) continue;
            [kept addObject:line];
        }
        tpl = [kept componentsJoinedByString:@"\n"];
    }
    NSDictionary<NSString *, NSString *> *vars = @{
        @"name": name ?: @"",
        @"time": timeText ?: @"",
        @"content": contentValue,
        @"wxid": wxid ?: @"",
        @"session": session ?: @"",
    };
    NSMutableString *out = [NSMutableString string];
    NSUInteger cursor = 0;
    while (cursor < tpl.length) {
        NSRange open = [tpl rangeOfString:@"{"
                                  options:0
                                    range:NSMakeRange(cursor, tpl.length - cursor)];
        if (open.location == NSNotFound) {
            [out appendString:[tpl substringFromIndex:cursor]];
            break;
        }
        if (open.location > cursor) {
            [out appendString:[tpl substringWithRange:NSMakeRange(cursor, open.location - cursor)]];
        }
        NSRange close = [tpl rangeOfString:@"}"
                                   options:0
                                     range:NSMakeRange(NSMaxRange(open), tpl.length - NSMaxRange(open))];
        if (close.location == NSNotFound) {
            [out appendString:[tpl substringFromIndex:open.location]];
            break;
        }
        NSString *key = [tpl substringWithRange:
            NSMakeRange(NSMaxRange(open), close.location - NSMaxRange(open))];
        NSString *value = vars[key];
        if (value) {
            [out appendString:value];
            cursor = NSMaxRange(close);
        } else {
            [out appendString:@"{"];
            cursor = NSMaxRange(open);
        }
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        if ([line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length == 0) {
            continue;
        }
        [lines addObject:line];
    }
    return [lines componentsJoinedByString:@"\n"] ?: @"";
}

bool MakeTextShell(uint8_t *bytes) {
    try {
        for (size_t offset : kStringOffsets) {
            reinterpret_cast<std::string *>(bytes + offset)->assign("");
        }
        uint32_t type = 1;
        uint32_t subtype = 0;
        uint64_t sourceID = 0;
        memcpy(bytes + kMessageTypeOffset, &type, sizeof(type));
        memcpy(bytes + kMessageTypeOffset + 4, &subtype, sizeof(subtype));
        memcpy(bytes + kMessageSourceIDOffset, &sourceID, sizeof(sourceID));
        return true;
    } catch (...) {
        return false;
    }
}

/// 通知文字只需要空的 type=1 MessageData，本地组外壳，不走 wrap 转换。
bool InitializeEmptyTextShell(OwnedMessage *shell) {
    if (!shell) return false;
    uintptr_t vtable = gSlide.load(std::memory_order_acquire) + kMessageDataVtableOffset;
    if (!vtable || !gDestroy.load(std::memory_order_acquire)) return false;

    shell->clear();
    memset(shell->bytes, 0, sizeof(shell->bytes));
    memcpy(shell->bytes, &vtable, sizeof(vtable));
    shell->live = true;
    if (!MakeTextShell(shell->bytes)) {
        shell->clear();
        return false;
    }
    // CopyShell() must deep-copy this object before forwarding. Exercise the
    // same copy/destroy path now, while no message is being sent.
    OwnedMessage verify;
    if (!verify.adoptCopy(shell->bytes)) {
        shell->clear();
        return false;
    }
    return true;
}

bool AssignTextShellString(const void *wrap, size_t wrapOffset,
                           uint8_t *bytes, size_t bytesOffset) {
    std::string value;
    if (!ReadLibcppStringAt(wrap, wrapOffset, value)) return false;
    try {
        reinterpret_cast<std::string *>(bytes + bytesOffset)->assign(value);
        return true;
    } catch (...) {
        return false;
    }
}

bool BuildTextSnapshot(const void *wrap, uint64_t serverID, OwnedMessage *out) {
    if (!wrap || serverID == 0 || !out) return false;
    if (!InitializeEmptyTextShell(out)) return false;
    if (!AssignTextShellString(wrap, 0x18, out->bytes, 0x10) ||
        !AssignTextShellString(wrap, 0x30, out->bytes, 0x28) ||
        !AssignTextShellString(wrap, 0x48, out->bytes, 0x40) ||
        !AssignTextShellString(wrap, 0x130, out->bytes, kMessageBodyOffset)) {
        out->clear();
        return false;
    }
    // 快照不保留原服务器 ID。撤回之后按这个 ID 转发，微信转出的是系统消息。
    uint64_t sourceID = 0;
    memcpy(out->bytes + kMessageSourceIDOffset, &sourceID, sizeof(sourceID));
    if (!IsNormalForwardBody(
            *reinterpret_cast<std::string *>(out->bytes + kMessageBodyOffset))) {
        out->clear();
        return false;
    }
    // Verify the final object can still be deep-copied for TakeSnapshot().
    OwnedMessage verify;
    if (!verify.adoptCopy(out->bytes)) {
        out->clear();
        return false;
    }
    return true;
}

bool ReadablePointer(uintptr_t address, size_t length) {
    if (address < 0x1000 || length == 0) return false;
    uint8_t probe[8] = {};
    const size_t head = length < sizeof(probe) ? length : sizeof(probe);
    if (!SafeRead(reinterpret_cast<const void *>(address), probe, head)) return false;
    if (length <= sizeof(probe)) return true;
    return SafeRead(reinterpret_cast<const void *>(address + length - sizeof(probe)),
                    probe, sizeof(probe));
}

bool ReadU64(const void *address, uint64_t *out) {
    return SafeRead(address, out, sizeof(*out));
}

uintptr_t ResolveNestedPointer(const uint8_t *wrap, size_t wrapOffset,
                               uintptr_t extA, size_t fallbackOffset) {
    uint64_t pointer = 0;
    if (!ReadU64(wrap + wrapOffset, &pointer)) return 0;
    if (pointer != 0) return static_cast<uintptr_t>(pointer);
    if (!extA || !ReadU64(reinterpret_cast<const void *>(extA + fallbackOffset), &pointer)) {
        return 0;
    }
    return static_cast<uintptr_t>(pointer);
}

/// Cheap predicate for sub_4CBFC30. The converter copies a 0x350 template,
/// then reads wrap strings, nested extension objects, and vtable+40. Login
/// wraps often have A51F728/A51F710 still null; converting those jumps to 0.
bool WrapConvertible(const void *wrap, uint32_t type, uint64_t serverID) {
    if (!wrap || serverID == 0 || !SnapshotType(type)) return false;
    const uintptr_t slide = gSlide.load(std::memory_order_acquire);
    const uintptr_t convert = gConvert.load(std::memory_order_acquire);
    if (!slide || !convert) return false;
    if (!VerifyEntry(slide, kConvertOffset, kConvertPrologue, @"撤回通知转换", nullptr)) {
        return false;
    }

    uint64_t vtable = 0;
    if (!ReadU64(wrap, &vtable) || vtable != slide + kWrapVtableOffset) return false;
    uint64_t virt40 = 0;
    if (!ReadU64(reinterpret_cast<const void *>(vtable + 40), &virt40) || virt40 == 0) {
        return false;
    }

    uint64_t extA = 0;
    uint64_t extB = 0;
    if (!ReadU64(reinterpret_cast<const void *>(slide + kExtGlobalAOffset), &extA) ||
        extA == 0 || !ReadablePointer(extA, 112)) {
        return false;
    }
    if (!ReadU64(reinterpret_cast<const void *>(slide + kExtGlobalBOffset), &extB) ||
        extB == 0 || !ReadablePointer(extB, 40)) {
        return false;
    }

    const auto *base = reinterpret_cast<const uint8_t *>(wrap);
    for (const WrapNestedSlot &slot : kWrapNested) {
        const uintptr_t resolved = ResolveNestedPointer(base, slot.wrapOffset, extA,
                                                        slot.fallbackOffset);
        if (resolved == 0 || !ReadablePointer(resolved, slot.readableBytes)) return false;
    }

    uint64_t object544 = 0;
    if (!ReadU64(base + 544, &object544)) return false;
    if (object544 != 0 && !ReadablePointer(object544, 16)) return false;

    uint64_t nested488 = ResolveNestedPointer(base, 488, extA, 88);
    uint64_t field24 = 0;
    uint64_t field32 = 0;
    if (nested488 != 0) {
        ReadU64(reinterpret_cast<const void *>(nested488 + 24), &field24);
        ReadU64(reinterpret_cast<const void *>(nested488 + 32), &field32);
    }
    if (field24 == 0) ReadU64(reinterpret_cast<const void *>(extB + 24), &field24);
    if (field32 == 0) ReadU64(reinterpret_cast<const void *>(extB + 32), &field32);
    if (field24 == 0 || field32 == 0) return false;
    if (!ReadablePointer(field24, 16) || !ReadablePointer(field32, 16)) return false;

    return true;
}

// 微信按 ARM64 大结构体约定把 MessageData 写到 x8。clang 对
// ConvertedMessage (*)(wrap) 也会把返回槽放进 x8。noinline 避免调用点
// 被改写成 void(wrap, out) 从而把 out 放进 x1。
__attribute__((noinline))
ConvertedMessage InvokeConvert(ConvertFn fn, const void *wrap) {
    return fn(wrap);
}

bool ConvertSnapshot(const void *wrap, uint64_t serverID, OwnedMessage *out) {
    if (!wrap || !out || serverID == 0) return false;
    uint32_t type = 0;
    const auto *base = reinterpret_cast<const uint8_t *>(wrap);
    if (!SafeRead(base + kWrapTypeOffset, &type, sizeof(type))) return false;
    if (!WrapConvertible(wrap, type, serverID)) return false;

    auto convert = reinterpret_cast<ConvertFn>(gConvert.load(std::memory_order_acquire));
    auto destroy = reinterpret_cast<MessageDestroyFn>(gDestroy.load(std::memory_order_acquire));
    if (!convert || !destroy) return false;

    ConvertedMessage converted;
    try {
        converted = InvokeConvert(convert, wrap);
    } catch (...) {
        return false;
    }

    uintptr_t vtable = 0;
    memcpy(&vtable, converted.bytes, sizeof(vtable));
    const uintptr_t expected =
        gSlide.load(std::memory_order_acquire) + kMessageDataVtableOffset;
    if (vtable != expected) return false;

    uint32_t outType = 0;
    memcpy(&outType, converted.bytes + kMessageTypeOffset, sizeof(outType));
    if (!SnapshotType(outType)) {
        destroy(converted.bytes);
        return false;
    }

    uint64_t sourceID = 0;
    memcpy(converted.bytes + kMessageSourceIDOffset, &sourceID, sizeof(sourceID));

    if (outType == 1 || outType == 48 || outType == 49) {
        try {
            const auto &body =
                *reinterpret_cast<const std::string *>(converted.bytes + kMessageBodyOffset);
            if (!IsNormalForwardBody(body)) {
                destroy(converted.bytes);
                return false;
            }
        } catch (...) {
            destroy(converted.bytes);
            return false;
        }
    }

    const bool copied = out->adoptCopy(converted.bytes);
    destroy(converted.bytes);
    return copied;
}

void StoreWrap(const void *wrap) {
    const bool recallText = gMaster.load(std::memory_order_acquire) &&
                            (gNotifySelf.load(std::memory_order_acquire) ||
                             gNotifySession.load(std::memory_order_acquire));
    const bool leaveText = gLeaveMonitorActive.load(std::memory_order_acquire) &&
                           (gLeaveNotifySelf.load(std::memory_order_acquire) ||
                            gLeaveNotifySession.load(std::memory_order_acquire));
    const bool wantText = recallText || leaveText;
    // “通知给自己”现在按消息类型分流：文字发文字通知，其他类型走原生转发。
    // 因此即使单独打开通知给自己，也要保留快照和类型。
    const bool wantSnapshots = gMaster.load(std::memory_order_acquire) &&
                               (gForwardSelf.load(std::memory_order_acquire) ||
                                gNotifySelf.load(std::memory_order_acquire));
    if (!wantText && !wantSnapshots) return;

    uint32_t type = 0;
    uint64_t serverID = 0;
    const auto *base = reinterpret_cast<const uint8_t *>(wrap);
    if (!SafeRead(base + kWrapTypeOffset, &type, sizeof(type)) ||
        !SafeRead(base + kWrapServerIDOffset, &serverID, sizeof(serverID))) {
        return;
    }
    if (type == 0 || type >= 10000) return;

    if (wantSnapshots && serverID != 0 && SnapshotType(type)) {
        std::lock_guard<std::mutex> lock(gMutex);
        if (gSnapshotTypes.find(serverID) == gSnapshotTypes.end()) {
            while (gSnapshotTypes.size() >= kMaxSnapshots) {
                gSnapshotTypes.erase(gSnapshotTypes.begin());
            }
            gSnapshotTypes.emplace(serverID, type);
        }
    }

    bool needShell = false;
    bool needSnapshot = false;
    {
        std::lock_guard<std::mutex> lock(gMutex);
        needShell = wantText && type == 1 && !gShell;
        needSnapshot = wantSnapshots && serverID != 0 && SnapshotType(type) &&
                       gSnapshots.find(serverID) == gSnapshots.end();
    }
    if (!needShell && !needSnapshot) return;

    if (needShell && type == 1) {
        std::lock_guard<std::mutex> lock(gMutex);
        if (!gShell) {
            auto shell = std::make_unique<OwnedMessage>();
            if (InitializeEmptyTextShell(shell.get())) {
                gShell = std::move(shell);
                Log("text shell ready");
            } else {
                os_log_error(NotifyLog(), "empty text shell failed");
            }
        }
    }

    if (!needSnapshot) return;

    auto snapshot = std::make_unique<OwnedMessage>();
    bool ready = false;
    if (WrapConvertible(wrap, type, serverID)) {
        ready = ConvertSnapshot(wrap, serverID, snapshot.get());
        if (!ready) Log("snapshot convert failed");
    } else if (type != 1) {
        os_log_info(NotifyLog(), "snapshot skipped: wrap not convertible type=%u", type);
    }
    if (!ready && type == 1) {
        ready = BuildTextSnapshot(wrap, serverID, snapshot.get());
        if (!ready) {
            Log("snapshot skipped: text fields unreadable");
            return;
        }
    }
    if (!ready) return;

    std::lock_guard<std::mutex> lock(gMutex);
    if (serverID != 0 && gSnapshots.find(serverID) == gSnapshots.end()) {
        while (gSnapshots.size() >= kMaxSnapshots) {
            gSnapshotTypes.erase(gSnapshots.begin()->first);
            gSnapshots.erase(gSnapshots.begin());
        }
        gSnapshots.emplace(serverID, std::move(snapshot));
        os_log_info(NotifyLog(), "snapshot ready type=%u", type);
    }
}

bool Submit(void *message, const std::string &recipient, const char *kind) {
    if (!RecipientAllowed(recipient)) {
        Log(kind);
        os_log_info(NotifyLog(), "%{public}s skipped: recipient rejected", kind);
        return false;
    }
    // 微信的 Magicdy 热更新会在启动后改写这个入口。Prepare 时匹配并不代表
    // 异步发送时仍然匹配；继续按旧 ABI 调用会进入空的回调槽并跳到地址 0。
    const uintptr_t slide = gSlide.load(std::memory_order_acquire);
    if (!slide || !VerifyEntry(slide, kForwardMessageOffset, kForwardPrologue,
                               @"撤回通知转发", nullptr)) {
        os_log_error(NotifyLog(), "%{public}s skipped: forward entry changed", kind);
        return false;
    }
    uintptr_t forwardService = 0;
    if (!SafeRead(reinterpret_cast<const void *>(slide + kForwardServiceGlobalOffset),
                  &forwardService, sizeof(forwardService)) || forwardService == 0) {
        os_log_info(NotifyLog(), "%{public}s skipped: forward service unavailable", kind);
        return false;
    }
    auto add = reinterpret_cast<AddRecipientFn>(gAddRecipient.load(std::memory_order_acquire));
    auto forward = reinterpret_cast<ForwardMessageFn>(gForward.load(std::memory_order_acquire));
    if (!add || !forward || !message) return false;
    try {
        ForwardTargets targets;
        add(&targets, 2, &recipient);
        const auto found = targets.accounts.find(2);
        if (targets.accounts.size() != 1 || found == targets.accounts.end() ||
            found->second.size() != 1 || *found->second.begin() != recipient ||
            !targets.additionalItems.empty() || !targets.wxworkRecipient.empty()) {
            os_log_error(NotifyLog(), "%{public}s target validation failed", kind);
            return false;
        }
        uintptr_t source[16] = {};
        ForwardCallbacks callbacks;
        auto noop = [] {};
        callbacks.first = noop;
        callbacks.second = noop;
        callbacks.third = noop;
        ForwardSubscription subscription = forward(
            &targets,
            message,
            source,
            reinterpret_cast<const uintptr_t *>(&callbacks));
        const bool submitted = subscription.identifier != 0 && subscription.cancellation != nullptr;
        os_log_info(NotifyLog(), "%{public}s submitted=%d", kind, submitted ? 1 : 0);
        return submitted;
    } catch (...) {
        os_log_error(NotifyLog(), "%{public}s threw", kind);
        return false;
    }
}

void FillNotice(uint8_t *bytes, const std::string &recipient, const std::string &body) {
    reinterpret_cast<std::string *>(bytes + 0x10)->assign("");
    reinterpret_cast<std::string *>(bytes + 0x28)->assign(recipient);
    reinterpret_cast<std::string *>(bytes + 0x40)->assign(recipient);
    reinterpret_cast<std::string *>(bytes + 0x58)->assign(recipient);
    reinterpret_cast<std::string *>(bytes + kMessageBodyOffset)->assign(body);
    uint32_t type = 1;
    uint64_t sourceID = 0;
    memcpy(bytes + kMessageTypeOffset, &type, sizeof(type));
    memcpy(bytes + kMessageSourceIDOffset, &sourceID, sizeof(sourceID));
}

std::unique_ptr<OwnedMessage> CopyShell(void) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gShell || !gShell->live) return nullptr;
    auto copy = std::make_unique<OwnedMessage>();
    if (!copy->adoptCopy(gShell->bytes)) return nullptr;
    return copy;
}

struct CapturedSnapshot {
    uint32_t type = 0;
    std::unique_ptr<OwnedMessage> message;
};

CapturedSnapshot TakeSnapshot(uint64_t serverID) {
    CapturedSnapshot result;
    std::lock_guard<std::mutex> lock(gMutex);
    auto type = gSnapshotTypes.find(serverID);
    if (type != gSnapshotTypes.end()) {
        result.type = type->second;
        gSnapshotTypes.erase(type);
    }
    auto found = gSnapshots.find(serverID);
    if (found == gSnapshots.end() || !found->second || !found->second->live) return result;
    auto copy = std::make_unique<OwnedMessage>();
    if (!copy->adoptCopy(found->second->bytes)) return result;
    gSnapshots.erase(found);
    result.message = std::move(copy);
    if (result.type == 0 && result.message) {
        memcpy(&result.type, result.message->bytes + kMessageTypeOffset, sizeof(result.type));
    }
    return result;
}

void SendText(const std::string &recipient, const std::string &body, const char *kind) {
    if (!RecipientAllowed(recipient) || body.empty()) {
        os_log_info(NotifyLog(), "%{public}s skipped", kind);
        return;
    }
    std::unique_ptr<OwnedMessage> message = CopyShell();
    if (!message) {
        os_log_info(NotifyLog(), "%{public}s skipped: no text shell yet", kind);
        return;
    }
    try {
        FillNotice(message->bytes, recipient, body);
    } catch (...) {
        os_log_error(NotifyLog(), "%{public}s shell fill threw", kind);
        return;
    }
    Submit(message->bytes, recipient, kind);
}

bool ContactsConfigured(void) {
    @autoreleasepool {
        if (!WCRContactNameNotifyEnabled()) return false;
        return WCRContactNameNotifyUserNames().count > 0;
    }
}

std::unique_ptr<OwnedMessage> CopySnapshot(const OwnedMessage *source) {
    if (!source) return nullptr;
    auto copy = std::make_unique<OwnedMessage>();
    if (!copy->adoptCopy(source->bytes)) return nullptr;
    return copy;
}

bool SubmitForward(std::unique_ptr<OwnedMessage> message,
                   const std::string &recipient, const char *kind) {
    if (!message) {
        Log("forward skipped: no snapshot");
        return false;
    }
    uint32_t type = 0;
    memcpy(&type, message->bytes + kMessageTypeOffset, sizeof(type));
    if (!SnapshotType(type)) {
        Log("forward skipped: unsupported type");
        return false;
    }
    if (type == 1 || type == 48 || type == 49) {
        try {
            const auto &body =
                *reinterpret_cast<const std::string *>(message->bytes + kMessageBodyOffset);
            if (!IsNormalForwardBody(body)) {
                Log("forward skipped: system message");
                return false;
            }
        } catch (...) {
            Log("forward skipped: body unreadable");
            return false;
        }
    }
    uint64_t sourceID = 0;
    memcpy(message->bytes + kMessageSourceIDOffset, &sourceID, sizeof(sourceID));
    return Submit(message->bytes, recipient, kind);
}

void SendNoticeOnce(const std::string &recipient, const std::string &body,
                    const char *kind, std::set<std::string> &sent) {
    if (!RecipientAllowed(recipient)) return;
    if (!sent.insert(recipient).second) return;
    SendText(recipient, body, kind);
}

void SendExtraContacts(const std::string &body, std::set<std::string> &sent) {
    NSArray<NSString *> *names = WCRContactNameNotifyUserNames();
    for (NSString *name in names) {
        std::string who = UTF8(name);
        SendNoticeOnce(who, body, "notice contact", sent);
    }
}

NSString *TextSnapshotContent(const CapturedSnapshot &snapshot) {
    if (!snapshot.message || snapshot.type != 1) return nil;
    try {
        const auto &body =
            *reinterpret_cast<const std::string *>(snapshot.message->bytes + kMessageBodyOffset);
        if (!IsNormalForwardBody(body)) return nil;
        return [NSString stringWithUTF8String:body.c_str()] ?: nil;
    } catch (...) {
        return nil;
    }
}

void Deliver(BOOL wantSelf, BOOL wantSession, BOOL wantContacts, BOOL wantForward,
             NSString *name, NSString *timeText, NSString *content,
             NSString *wxid, NSString *session, uint64_t serverID) {
    if (![NSThread isMainThread] || !gReady.load(std::memory_order_acquire)) return;
    std::string selfID = UTF8(WCROriginalIDSelfWXID());
    std::string sessionID = UTF8(session);
    std::string targetID = UTF8(WCRRecallNotifyTargetSession());
    const bool selfOK = RecipientAllowed(selfID);
    if (!RecipientAllowed(targetID)) targetID = selfID;
    const bool targetOK = RecipientAllowed(targetID);

    CapturedSnapshot captured;
    if ((wantSelf || wantForward) && serverID != 0) {
        captured = TakeSnapshot(serverID);
    }
    const uint32_t type = captured.type;
    const bool typeKnown = SnapshotType(type);
    const bool selfText = wantSelf && targetOK && (type == 1 || !typeKnown);
    const bool selfForward = wantSelf && targetOK && typeKnown && type != 1;
    bool selfFallbackText = selfForward && !captured.message;
    bool selfForwarded = false;

    // 非文字先走官方转发；失败时保留文字通知兜底，避免完全静默。
    if (selfForward && captured.message) {
        selfForwarded = SubmitForward(CopySnapshot(captured.message.get()), targetID,
                                      "forward notice self");
        selfFallbackText = !selfForwarded;
    }

    NSString *notice = nil;
    std::string body;
    const bool textNeeded = selfText || selfFallbackText || wantSession || wantContacts;
    if (textNeeded) {
        NSString *noticeContent = content;
        NSString *snapshotText = TextSnapshotContent(captured);
        if (snapshotText.length) noticeContent = snapshotText;
        notice = RenderNotice(WCRRecallNotifyStoredTemplate(), name, timeText,
                              noticeContent, wxid, session);
        body = UTF8(notice);
        if (body.size() > kMaxNoticeBytes) body.resize(kMaxNoticeBytes);
        if (body.empty()) Log("notice empty");
    }

    std::set<std::string> textSent;
    if (!body.empty()) {
        if (selfText || selfFallbackText) {
            SendNoticeOnce(targetID, body, "notice self", textSent);
        }
        if (wantSession) {
            SendNoticeOnce(sessionID, body, "notice session", textSent);
        }
        if (wantContacts) {
            SendExtraContacts(body, textSent);
        }
        if (!gShell && (selfText || selfFallbackText || wantSession || wantContacts)) {
            Log("notice waiting for a text message shell");
        }
    }

    if (!wantForward) return;
    if (!selfOK || serverID == 0) {
        Log("forward skipped: no self id");
        return;
    }
    if (!captured.message) {
        Log("forward skipped: no snapshot");
        return;
    }
    // 目标正好是自己且已经由“通知给自己”转发过时不重复发。
    if (selfForwarded && targetID == selfID) return;
    std::unique_ptr<OwnedMessage> copy = CopySnapshot(captured.message.get());
    if (!copy) {
        Log("forward skipped: copy failed");
        return;
    }
    SubmitForward(std::move(copy), selfID, "forward normal");
}

}  // namespace

BOOL WCRRecallNotifySupportsProfile(const WCRPatchProfile *profile) {
    if (!profile || !profile->buildVersion) return NO;
    if (strcmp(profile->buildVersion, "270135") != 0) return NO;
    return profile->messageFinalizerAddress != 0;
}

BOOL WCRRecallNotifyPrepare(NSError **error) {
    RefreshFlags();
    if (gReady.load(std::memory_order_acquire)) return YES;

    uintptr_t slide = CurrentWeChatSlide();
    if (!slide) {
        if (error) *error = NotifyError(@"wechat.dylib 尚未加载");
        return NO;
    }
    if (!VerifyEntry(slide, kMessageCopyOffset, kCopyPrologue, @"撤回通知消息复制", error) ||
        !VerifyEntry(slide, kMessageDestroyOffset, kDestroyPrologue, @"撤回通知消息析构", error) ||
        !VerifyEntry(slide, kAddRecipientOffset, kAddRecipientPrologue, @"撤回通知收件人", error) ||
        !VerifyEntry(slide, kForwardMessageOffset, kForwardPrologue, @"撤回通知转发", error)) {
        return NO;
    }

    gSlide.store(slide, std::memory_order_release);
    gCopy.store(slide + kMessageCopyOffset, std::memory_order_release);
    gDestroy.store(slide + kMessageDestroyOffset, std::memory_order_release);
    gAddRecipient.store(slide + kAddRecipientOffset, std::memory_order_release);
    gForward.store(slide + kForwardMessageOffset, std::memory_order_release);
    if (VerifyEntry(slide, kConvertOffset, kConvertPrologue, @"撤回通知转换", nullptr)) {
        gConvert.store(slide + kConvertOffset, std::memory_order_release);
    } else {
        gConvert.store(0, std::memory_order_release);
        Log("convert entry mismatch; original forward falls back to text");
    }
    gReady.store(true, std::memory_order_release);
    Log("prepare ok");
    return YES;
}

BOOL WCRRecallNotifyIsReady(void) {
    return gReady.load(std::memory_order_acquire);
}

BOOL WCRRecallNotifyMasterEnabled(void) {
    RefreshFlags();
    return gMaster.load(std::memory_order_acquire);
}

void WCRRecallNotifySetMasterEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kMasterKey];
    RefreshFlags();
    WCRRecallNotifyReleaseHeldMessages();
}

BOOL WCRRecallNotifySelfEnabled(void) {
    RefreshFlags();
    return gNotifySelf.load(std::memory_order_acquire);
}

void WCRRecallNotifySetSelfEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kSelfKey];
    RefreshFlags();
    WCRRecallNotifyReleaseHeldMessages();
}

NSString *WCRRecallNotifyTargetSession(void) {
    @autoreleasepool {
        NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:kTargetSessionKey];
        NSString *trimmed = [stored stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        return RecipientAllowed(UTF8(trimmed)) ? [trimmed copy] : @"";
    }
}

BOOL WCRRecallNotifySetTargetSession(NSString *session) {
    @autoreleasepool {
        NSString *trimmed = [session stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        if (trimmed.length == 0) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:kTargetSessionKey];
            return YES;
        }
        if (!RecipientAllowed(UTF8(trimmed))) return NO;
        [[NSUserDefaults standardUserDefaults] setObject:trimmed forKey:kTargetSessionKey];
        return YES;
    }
}

BOOL WCRRecallNotifySessionEnabled(void) {
    RefreshFlags();
    return gNotifySession.load(std::memory_order_acquire);
}

void WCRRecallNotifySetSessionEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kSessionKey];
    RefreshFlags();
}

BOOL WCRRecallNotifyForwardSelfEnabled(void) {
    RefreshFlags();
    return gForwardSelf.load(std::memory_order_acquire);
}

void WCRRecallNotifySetForwardSelfEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kForwardKey];
    RefreshFlags();
    WCRRecallNotifyReleaseHeldMessages();
}

BOOL WCRRecallNotifyLeaveSessionEnabled(void) {
    RefreshFlags();
    return gLeaveNotifySession.load(std::memory_order_acquire);
}

void WCRRecallNotifySetLeaveSessionEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kLeaveSessionKey];
    RefreshFlags();
}

BOOL WCRRecallNotifyLeaveSelfEnabled(void) {
    RefreshFlags();
    return gLeaveNotifySelf.load(std::memory_order_acquire);
}

void WCRRecallNotifySetLeaveSelfEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kLeaveSelfKey];
    RefreshFlags();
}

BOOL WCRRecallNotifyLeaveWantsCapture(void) {
    return gLeaveMonitorActive.load(std::memory_order_acquire) &&
           (gLeaveNotifySession.load(std::memory_order_acquire) ||
            gLeaveNotifySelf.load(std::memory_order_acquire));
}

void WCRRecallNotifySetLeaveMonitorActive(BOOL active) {
    gLeaveMonitorActive.store(active == YES, std::memory_order_release);
}

BOOL WCRRecallNotifyWantsCapture(void) {
    RefreshFlags();
    const bool recall = gMaster.load(std::memory_order_acquire) &&
                        (gNotifySelf.load(std::memory_order_acquire) ||
                         gNotifySession.load(std::memory_order_acquire) ||
                         gForwardSelf.load(std::memory_order_acquire) ||
                         ContactsConfigured());
    return recall || WCRRecallNotifyLeaveWantsCapture();
}

void WCRRecallNotifyReleaseHeldMessages(void) {
    RefreshFlags();
    const bool keepShell =
        (gMaster.load(std::memory_order_acquire) &&
         (gNotifySelf.load(std::memory_order_acquire) ||
          gNotifySession.load(std::memory_order_acquire) ||
          ContactsConfigured())) ||
        (gLeaveMonitorActive.load(std::memory_order_acquire) &&
         (gLeaveNotifySelf.load(std::memory_order_acquire) ||
          gLeaveNotifySession.load(std::memory_order_acquire)));
    const bool keepSnapshots = gMaster.load(std::memory_order_acquire) &&
                               (gForwardSelf.load(std::memory_order_acquire) ||
                                gNotifySelf.load(std::memory_order_acquire));
    std::lock_guard<std::mutex> lock(gMutex);
    if (!keepShell) gShell.reset();
    if (!keepSnapshots) {
        gSnapshots.clear();
        gSnapshotTypes.clear();
    }
}

void WCRRecallNotifySendLeaveText(NSString *body, NSString *groupID) {
    RefreshFlags();
    if (!gReady.load(std::memory_order_acquire) ||
        !gLeaveMonitorActive.load(std::memory_order_acquire)) return;
    const BOOL wantSelf = gLeaveNotifySelf.load(std::memory_order_acquire);
    const BOOL wantSession = gLeaveNotifySession.load(std::memory_order_acquire);
    if ((!wantSelf && !wantSession) || body.length == 0) return;

    NSString *bodyCopy = [body copy];
    NSString *groupCopy = [groupID copy] ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            std::string notice = UTF8(bodyCopy);
            if (notice.size() > kMaxNoticeBytes) notice.resize(kMaxNoticeBytes);
            if (notice.empty()) return;
            const std::string selfID = UTF8(WCROriginalIDSelfWXID());
            const std::string sessionID = UTF8(groupCopy);
            if (wantSelf && RecipientAllowed(selfID)) {
                SendText(selfID, notice, "leave notice self");
            }
            if (wantSession && RecipientAllowed(sessionID) && sessionID != selfID) {
                SendText(sessionID, notice, "leave notice session");
            }
        }
    });
}

NSString *WCRRecallNotifyDefaultTemplate(void) {
    return @"拦截一条撤回消息\n撤回人：{name}\n撤回时间：{time}\n撤回内容：{content}";
}

NSString *WCRRecallNotifyStoredTemplate(void) {
    @autoreleasepool {
        NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:kTemplateKey];
        NSString *trimmed = [stored stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        if (trimmed.length == 0 || trimmed.length > kMaxTemplateBytes) {
            return WCRRecallNotifyDefaultTemplate();
        }
        return trimmed;
    }
}

void WCRRecallNotifySetStoredTemplate(NSString *templateString) {
    @autoreleasepool {
        NSString *trimmed = [templateString stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        if (trimmed.length == 0 || trimmed.length > kMaxTemplateBytes) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:kTemplateKey];
            return;
        }
        [[NSUserDefaults standardUserDefaults] setObject:trimmed forKey:kTemplateKey];
    }
}

void WCRRecallNotifyObserveWrap(const void *wrap) {
    if (!wrap || !gReady.load(std::memory_order_acquire)) return;
    try {
        @try {
            StoreWrap(wrap);
        } @catch (...) {
        }
    } catch (...) {
    }
}

void WCRRecallNotifyOnUniqueRecall(NSString *name, NSString *timeText, NSString *content,
                                   NSString *wxid, NSString *session, uint64_t serverID) {
    RefreshFlags();
    if (!gMaster.load(std::memory_order_acquire) || !gReady.load(std::memory_order_acquire)) return;
    const BOOL wantSelf = gNotifySelf.load(std::memory_order_acquire);
    const BOOL wantSession = gNotifySession.load(std::memory_order_acquire);
    const BOOL wantForward = gForwardSelf.load(std::memory_order_acquire);
    const BOOL wantContacts = ContactsConfigured();
    if (!wantSelf && !wantSession && !wantForward && !wantContacts) return;

    NSString *nameCopy = [name copy] ?: @"";
    NSString *timeCopy = [timeText copy] ?: @"";
    NSString *contentCopy = [content copy] ?: @"";
    NSString *wxidCopy = [wxid copy] ?: @"";
    NSString *sessionCopy = [session copy] ?: @"";
    // 灰字由解析器的调用方在返回后插入。同一轮里立刻发送，会把这条系统提示盖掉。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @autoreleasepool {
            try {
                Deliver(wantSelf, wantSession, wantContacts, wantForward, nameCopy, timeCopy,
                        contentCopy, wxidCopy, sessionCopy, serverID);
            } catch (...) {
                Log("deliver threw");
            }
        }
    });
}

NSString *WCRRecallNotifyRenderForTesting(NSString *templateString, NSString *name,
                                          NSString *timeText, NSString *content,
                                          NSString *wxid, NSString *session) {
    return RenderNotice(templateString, name, timeText, content, wxid, session);
}

BOOL WCRRecallNotifyRecipientAllowedForTesting(NSString *value) {
    return RecipientAllowed(UTF8(value));
}

BOOL WCRRecallNotifyBodyIsNormalForwardForTesting(NSString *body) {
    return IsNormalForwardBody(UTF8(body));
}
