#import "WCROriginalID.h"

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

NSString *const WCROriginalIDFrontDidChangeNotification =
    @"WCROriginalIDFrontDidChangeNotification";

namespace {

// 270135 消息对象布局（libc++ std::string 每字段 24 字节）：
//   +0x0C 消息类型(u32)   +0x18 fromUsr   +0x30 toUsr   +0x48 群内真实发送者
//   自己发的群消息：+0x18=self、+0x30=群ID；收到的群消息：+0x18=群ID、+0x30=self；
//   私聊：一方 peer 一方 self。+0x48 群消息时是成员 wxid/别名，不进会话表。
//   正文 std::string 在 +0x130（WCRPatchProfiles 登记，本模块不再用它）。
constexpr uint64_t kFromUsrOffset = 0x18;
constexpr uint64_t kToUsrOffset = 0x30;
[[maybe_unused]] constexpr uint64_t kActualFromOffset = 0x48;
constexpr size_t kMaxSessions = 128;
constexpr size_t kMaxValueBytes = 64;

struct SessionRecord {
    std::string value;
    std::string kind;
    time_t lastSeen;
};

std::mutex gMutex;
std::vector<SessionRecord> gSessions;
std::string gSelfID;   // 登录目录名，或群消息里非 @chatroom 的一端
std::string gFront;    // 当前打开的会话。不靠 lastSeen 冒充，后来的消息顶不掉它

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

// libc++ std::string 读取（短串内联 / 长串指针），与 WCRMessageCapture 同约定：
// 第 24 字节最高位是 long 标志，短串低 7 位是长度。
bool ReadLibcppStringAt(const void *object, std::string &out) {
    const auto *bytes = reinterpret_cast<const uint8_t *>(object);
    if (!IsAddressRangeReadable(bytes, 24)) return false;

    const int8_t flag = static_cast<int8_t>(bytes[23]);
    if (flag >= 0) {
        size_t length = static_cast<uint8_t>(flag) & 0x7F;
        if (length == 0 || length > 22) return false;
        out.assign(reinterpret_cast<const char *>(bytes), length);
        return true;
    }

    const char *data = nullptr;
    uint64_t rawLength = 0;
    memcpy(&data, bytes, sizeof(data));
    memcpy(&rawLength, bytes + 8, sizeof(rawLength));
    size_t length = static_cast<size_t>(rawLength & 0x7FFFFFFFFFFFFFFFULL);
    if (!data || length == 0 || length > kMaxValueBytes ||
        !IsAddressRangeReadable(data, length)) {
        return false;
    }
    out.assign(data, length);
    return true;
}

bool IsIDCharset(const std::string &value) {
    for (unsigned char c : value) {
        if (!(isalnum(c) || c == '_' || c == '-' || c == '@')) return false;
    }
    return true;
}

std::string KindForValue(const std::string &value) {
    auto startsWith = [&value](const char *prefix) {
        return value.rfind(prefix, 0) == 0;
    };
    auto endsWith = [&value](const char *suffix) {
        size_t n = strlen(suffix);
        return value.size() >= n && value.compare(value.size() - n, n, suffix) == 0;
    };
    if (endsWith("@chatroom")) return "群";
    if (startsWith("gh_")) return "公众号";
    if (endsWith("@openim")) return "企业微信";
    return "用户";
}

bool ReadWrapString(const void *object, uint64_t offset, std::string &out) {
    const auto *base = reinterpret_cast<const uint8_t *>(object);
    if (!ReadLibcppStringAt(base + offset, out)) return false;
    if (out.empty() || out.size() > kMaxValueBytes || !IsIDCharset(out)) return false;
    return true;
}

void EvictIfNeeded(const std::string &keep) {
    while (gSessions.size() > kMaxSessions) {
        auto victim = gSessions.end();
        for (auto it = gSessions.begin(); it != gSessions.end(); ++it) {
            if (it->value == keep) continue;
            if (!gFront.empty() && it->value == gFront) continue;
            if (victim == gSessions.end() || it->lastSeen < victim->lastSeen) victim = it;
        }
        if (victim == gSessions.end()) return;
        gSessions.erase(victim);
    }
}

void TouchSession(const std::string &value, const std::string &kind, bool bumpSeen) {
    std::lock_guard<std::mutex> lock(gMutex);
    for (auto &record : gSessions) {
        if (record.value != value) continue;
        if (bumpSeen) record.lastSeen = time(nullptr);
        if (!kind.empty() && record.kind != kind) record.kind = kind;
        return;
    }
    gSessions.push_back({value, kind, time(nullptr)});
    EvictIfNeeded(value);
}

void TouchFront(const std::string &value, const std::string &kind) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gSelfID.empty() && value == gSelfID) return;
    gFront = value;
    for (const auto &record : gSessions) {
        if (record.value == value) return;
    }
    gSessions.push_back({value, kind, time(nullptr)});
    EvictIfNeeded(value);
}

void RecordSession(const std::string &value, const std::string &kind) {
    TouchSession(value, kind, true);
}

// 微信沙盒里 NSHomeDirectory 就是容器根。登录目录名即自己的 wxid，
// 这样私聊不用先等一条群消息才能和自己区分开。多个账号目录则不猜。
void EnsureSelfFromLogin(void) {
    static std::once_flag once;
    std::call_once(once, [] {
        @autoreleasepool {
            NSString *login = [NSHomeDirectory() stringByAppendingPathComponent:
                @"Documents/xwechat_files/all_users/login"];
            NSArray<NSString *> *names =
                [[NSFileManager defaultManager] contentsOfDirectoryAtPath:login error:nil];
            NSString *found = nil;
            NSFileManager *files = [NSFileManager defaultManager];
            for (NSString *name in names) {
                if (name.length == 0 || [name hasPrefix:@"."]) continue;
                BOOL isDir = NO;
                NSString *path = [login stringByAppendingPathComponent:name];
                if (![files fileExistsAtPath:path isDirectory:&isDir] || !isDir) continue;
                if (found) return;
                found = name;
            }
            if (found.length == 0 || found.length > kMaxValueBytes) return;
            std::string value(found.UTF8String ?: "");
            if (value.empty() || !IsIDCharset(value)) return;
            std::lock_guard<std::mutex> lock(gMutex);
            if (gSelfID.empty()) gSelfID = std::move(value);
        }
    });
}

}  // namespace

NSString *WCROriginalIDSelfWXID(void) {
    EnsureSelfFromLogin();
    std::string value;
    {
        std::lock_guard<std::mutex> lock(gMutex);
        value = gSelfID;
    }
    if (value.empty()) return nil;
    return [NSString stringWithUTF8String:value.c_str()];
}

void WCRObserveMessageObject(const void *object) {
    if (!object) return;
    EnsureSelfFromLogin();

    std::string fromUsr;
    std::string toUsr;
    if (!ReadWrapString(object, kFromUsrOffset, fromUsr) ||
        !ReadWrapString(object, kToUsrOffset, toUsr)) {
        return;
    }

    auto endsWithChatroom = [](const std::string &value) {
        const char *suffix = "@chatroom";
        size_t n = strlen(suffix);
        return value.size() >= n && value.compare(value.size() - n, n, suffix) == 0;
    };
    bool fromIsGroup = endsWithChatroom(fromUsr);
    bool toIsGroup = endsWithChatroom(toUsr);
    if (fromIsGroup != toIsGroup) {
        // 群消息：群 ID 即会话；另一端是自己的 wxid，顺手学习（后续私聊用）。
        RecordSession(fromIsGroup ? fromUsr : toUsr, "群");
        const std::string &other = fromIsGroup ? toUsr : fromUsr;
        if (!other.empty() && !endsWithChatroom(other)) {
            std::lock_guard<std::mutex> lock(gMutex);
            if (gSelfID != other) gSelfID = other;
        }
        return;
    }

    // 私聊：两端里不是自己的那个是会话；self 未知时先跳过（一条群消息即可学到）。
    std::string self;
    {
        std::lock_guard<std::mutex> lock(gMutex);
        self = gSelfID;
    }
    if (self.empty()) return;
    std::string session;
    if (fromUsr == self) session = toUsr;
    else if (toUsr == self) session = fromUsr;
    else return;
    if (session.empty() || session == self) return;
    RecordSession(session, KindForValue(session));
}

void WCROriginalIDObserveObject(const void *object) {
    // 捕获点在任何线程触发；读取全部带防御，异常不得外抛。
    @try {
        WCRObserveMessageObject(object);
    } @catch (...) {
    }
}

static void WCRPostFrontChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:WCROriginalIDFrontDidChangeNotification
                          object:nil];
    });
}

extern "C" void WCROriginalIDNoteSelectedUsername(const void *username) {
    @try {
        if (!username) return;
        EnsureSelfFromLogin();
        std::string value;
        if (!ReadLibcppStringAt(username, value)) return;
        if (value.empty() || value.size() > kMaxValueBytes || !IsIDCharset(value)) return;
        TouchFront(value, KindForValue(value));
        WCRPostFrontChanged();
    } @catch (...) {
    }
}

NSString *WCROriginalIDFrontValue(void) {
    std::string front;
    {
        std::lock_guard<std::mutex> lock(gMutex);
        front = gFront;
    }
    if (front.empty()) return @"";
    return [NSString stringWithUTF8String:front.c_str()] ?: @"";
}

NSArray<NSDictionary<NSString *, NSString *> *> *WCROriginalIDRecentSessions(void) {
    std::vector<SessionRecord> snapshot;
    std::string front;
    {
        std::lock_guard<std::mutex> lock(gMutex);
        snapshot = gSessions;
        front = gFront;
    }
    std::sort(snapshot.begin(), snapshot.end(),
              [&front](const SessionRecord &a, const SessionRecord &b) {
                  bool aFront = !front.empty() && a.value == front;
                  bool bFront = !front.empty() && b.value == front;
                  if (aFront != bFront) return aFront;
                  return a.lastSeen > b.lastSeen;
              });

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *result = [NSMutableArray array];
    NSDateFormatter *today = [[NSDateFormatter alloc] init];
    today.dateFormat = @"HH:mm";
    NSDateFormatter *otherDay = [[NSDateFormatter alloc] init];
    otherDay.dateFormat = @"M/d HH:mm";
    for (const auto &record : snapshot) {
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:record.lastSeen];
        NSString *seen = [[NSCalendar currentCalendar] isDateInToday: date]
            ? [today stringFromDate:date]
            : [otherDay stringFromDate:date];
        BOOL isFront = !front.empty() && record.value == front;
        [result addObject:@{
            @"kind": [NSString stringWithUTF8String:record.kind.c_str()] ?: @"ID",
            @"value": [NSString stringWithUTF8String:record.value.c_str()] ?: @"",
            @"lastSeen": seen ?: @"",
            @"epoch": [NSString stringWithFormat:@"%ld", (long)record.lastSeen],
            @"front": isFront ? @"1" : @"0",
        }];
    }
    return result;
}

void WCROriginalIDClearSessions(void) {
    {
        std::lock_guard<std::mutex> lock(gMutex);
        gSessions.clear();
        gFront.clear();
    }
    WCRPostFrontChanged();
}
