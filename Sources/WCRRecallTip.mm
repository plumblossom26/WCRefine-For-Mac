#import "WCRRecallTip.h"
#import "WCRCodePatch.h"
#import "WCRMessageCapture.h"
#import "WCRRecallNotify.h"
#import "WCRContactName.h"

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach-o/dyld.h>
#import <libkern/OSCacheControl.h>
#import <sys/mman.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <map>
#include <set>
#include <string>
#include <vector>

#ifdef WCR_TIP_DEBUG
#define WCRTipDebug(...) fprintf(stderr, __VA_ARGS__)
#else
#define WCRTipDebug(...)
#endif

namespace {

constexpr size_t kEntryBytes = 16;
constexpr size_t kTrampolineBytes = 32;
constexpr size_t kMaxHistoryCount = 30;
constexpr size_t kMaxContentBytes = 240;
constexpr size_t kMaxTemplateBytes = 1000;
constexpr size_t kMaxTipCacheSize = 128;
constexpr char kWeChatDylibSuffix[] = "/Contents/Resources/wechat.dylib";

// 渲染出的提示条永远带一个零宽空格哨兵：微信对我们改写过的系统消息可能
// 再走一轮 parseRevokeXML（提示文本那时会出现在 <content> 里），靠哨兵
// 识别“这是自己的提示”，跳过重写，避免提示递归污染自己。
constexpr const char *kTipSentinelUTF8 = "\xE2\x80\x8B";  // U+200B

using ParseRevokeXMLFn = bool (*)(void *, std::string *, void *);

static std::atomic_bool gInstalled(false);
static uint8_t *gEntryAddress = nullptr;
static uint8_t gSavedEntry[kEntryBytes] = {};
static void *gTrampoline = nullptr;
static ParseRevokeXMLFn gOriginalParseRevokeXML = nullptr;
static WCRPatchProfile gProfile = {};
static std::mutex gSeenMutex;
static std::set<std::string> gSeenEvents;
// dedupKey -> 已渲染的提示文本。同一撤回事件被微信再次解析时用它恢复提示，
// 而不是拿被污染的二次 XML 重新渲染。
static std::mutex gTipCacheMutex;
static std::map<std::string, std::string> gTipCache;
static NSMutableArray<NSDictionary<NSString *, NSString *> *> *gHistory = nil;
static dispatch_once_t gHistoryOnce;

bool LooksLikeOurTip(const std::string &text) {
    if (text.find(kTipSentinelUTF8) != std::string::npos) return true;
    // 兜底：旧版本（无哨兵）用默认模板渲染出的提示。
    return text.find("已拦截一条撤回消息") != std::string::npos;
}

// 调用方会先把整段 XML 拷进 +0x1D0。短语出现在 XML 里不等于灰字已经是纯文本提示。
bool SlotAlreadyShowsTip(const std::string &slot) {
    if (slot.find('<') != std::string::npos) return false;
    return LooksLikeOurTip(slot);
}

NSError *WCRTipError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMac.RecallTip"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"撤回提示错误"}];
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

bool WriteProcessBytes(void *destination, const void *source, size_t length) {
    return WCRPatchCodeBytes(destination, source, length, nullptr);
}

const void *FindLoadedWeChatDylib(uintptr_t *slideOut) {
    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const char *name = _dyld_get_image_name(index);
        if (!name) continue;
        std::string path(name);
        const size_t suffixLength = strlen(kWeChatDylibSuffix);
        if (path.size() < suffixLength ||
            path.compare(path.size() - suffixLength, suffixLength, kWeChatDylibSuffix) != 0) {
            continue;
        }
        if (slideOut) *slideOut = static_cast<uintptr_t>(_dyld_get_image_vmaddr_slide(index));
        return _dyld_get_image_header(index);
    }
    return nullptr;
}

std::string Trim(std::string value) {
    const char *whitespace = " \t\r\n";
    size_t first = value.find_first_not_of(whitespace);
    if (first == std::string::npos) return "";
    size_t last = value.find_last_not_of(whitespace);
    return value.substr(first, last - first + 1);
}

std::string StripCDATA(std::string value) {
    size_t start = value.find("<![CDATA[");
    if (start != std::string::npos) {
        size_t end = value.find("]]>", start + 9);
        if (end != std::string::npos) {
            return value.substr(start + 9, end - start - 9);
        }
    }
    return value;
}

std::string DecodeXMLEntities(std::string value) {
    struct Entity { const char *encoded; const char *decoded; };
    static const Entity entities[] = {
        {"&quot;", "\""}, {"&apos;", "'"}, {"&lt;", "<"},
        {"&gt;", ">"}, {"&amp;", "&"},
    };
    for (const auto &entity : entities) {
        size_t position = 0;
        while ((position = value.find(entity.encoded, position)) != std::string::npos) {
            value.replace(position, strlen(entity.encoded), entity.decoded);
            position += strlen(entity.decoded);
        }
    }
    return value;
}

std::string TagValue(const std::string &xml, const std::string &tag) {
    std::string open = "<" + tag + ">";
    std::string close = "</" + tag + ">";
    size_t start = xml.find(open);
    if (start == std::string::npos) return "";
    start += open.size();
    size_t end = xml.find(close, start);
    if (end == std::string::npos) return "";
    std::string value = xml.substr(start, end - start);
    return DecodeXMLEntities(Trim(StripCDATA(value)));
}

bool LooksLikeRevokeXML(const std::string &xml) {
    return xml.find("<revokemsg>") != std::string::npos ||
           xml.find("type=\"revokemsg\"") != std::string::npos ||
           xml.find("type='revokemsg'") != std::string::npos;
}

std::string StripOuterQuotes(std::string value) {
    value = Trim(value);
    if (value.size() >= 2) {
        unsigned char first = value.front();
        unsigned char last = value.back();
        if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
            value = Trim(value.substr(1, value.size() - 2));
        }
    }
    return value;
}

bool IsSelfRecall(const std::string &tip) {
    static const char *markers[] = {
        "你撤回", "你收回", "你回收", "You recalled", "You unsent",
    };
    for (const char *marker : markers) {
        if (tip.find(marker) != std::string::npos) return true;
    }
    return false;
}

std::string DisplayNameFromTip(const std::string &tip) {
    std::string display = tip;
    size_t marker = display.find("撤回");
    if (marker != std::string::npos) display = display.substr(0, marker);
    else {
        marker = display.find(" recalled ");
        if (marker != std::string::npos) display = display.substr(0, marker);
    }
    return StripOuterQuotes(display);
}

std::string WxidFromText(const std::string &text) {
    size_t start = text.find("wxid_");
    if (start == std::string::npos) return "";
    size_t end = start;
    while (end < text.size()) {
        unsigned char c = text[end];
        if (!(isalnum(c) || c == '_' || c == '-')) break;
        end++;
    }
    return text.substr(start, end - start);
}

std::string FirstTagValue(const std::string &xml, const std::vector<std::string> &tags) {
    for (const auto &tag : tags) {
        std::string value = TagValue(xml, tag);
        if (!value.empty()) return value;
    }
    return "";
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
    if (!data || length == 0 || length > 4096 || !IsAddressRangeReadable(data, length)) {
        return false;
    }
    out.assign(data, length);
    return true;
}

std::string ScanMessageForUserID(void *message, const std::string &session) {
    if (!message) return "";
    const auto *base = reinterpret_cast<const uint8_t *>(message);
    for (size_t offset = 0; offset < 0x1C0; offset += 8) {
        std::string value;
        if (!ReadLibcppStringAt(base + offset, value)) continue;
        if (value == session) continue;
        if (value.rfind("wxid_", 0) == 0 || value.rfind("openid_", 0) == 0) {
            return value;
        }
    }
    return "";
}

std::string UserIDFromXML(const std::string &xml,
                          const std::string &session,
                          const std::string &tip,
                          void *message) {
    static const std::vector<std::string> tags = {
        "fromusername", "fromusr", "fromuser", "username", "wxid", "sender",
    };
    std::string value = FirstTagValue(xml, tags);
    if (!value.empty()) return value;
    if (!session.empty() && session.find("@chatroom") == std::string::npos) return session;
    value = WxidFromText(tip);
    if (!value.empty()) return value;
    return ScanMessageForUserID(message, session);
}

std::string GroupIDFromSession(const std::string &session) {
    return session.find("@chatroom") != std::string::npos ? session : "";
}

std::string FormatTime(const std::string &xml) {
    std::string raw = TagValue(xml, "createtime");
    NSTimeInterval timestamp = raw.empty() ? [[NSDate date] timeIntervalSince1970] : strtod(raw.c_str(), nullptr);
    if (timestamp <= 0) timestamp = [[NSDate date] timeIntervalSince1970];
    @autoreleasepool {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"HH:mm:ss";
        NSString *text = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]] ?: @"";
        return text.UTF8String ?: "";
    }
}

std::string TruncateUTF8(std::string value, size_t maxBytes) {
    value = Trim(value);
    if (value.size() <= maxBytes) return value;
    size_t end = maxBytes;
    while (end > 0 && (static_cast<unsigned char>(value[end]) & 0xC0) == 0x80) end--;
    return value.substr(0, end) + "…";
}

NSString *StringFromUTF8(const std::string &value);

struct RevokeFields {
    std::string display;
    std::string userID;
    std::string groupID;
    std::string session;
    std::string time;
    std::string content;
    std::string originalTip;
};

RevokeFields ParseRevokeFields(const std::string &xml,
                               const std::string &originalTip,
                               void *message) {
    RevokeFields fields;
    fields.originalTip = originalTip;
    fields.session = TagValue(xml, "session");
    fields.userID = UserIDFromXML(xml, fields.session, originalTip, message);
    fields.groupID = GroupIDFromSession(fields.session);
    fields.display = DisplayNameFromTip(originalTip);
    if (fields.display.empty()) fields.display = "未知用户";
    @autoreleasepool {
        const bool skip = IsSelfRecall(originalTip) || fields.userID.empty() ||
                          fields.display == "你" || fields.display == "未知用户";
        if (!skip) {
            NSString *who = [NSString stringWithUTF8String:fields.userID.c_str()];
            NSString *seen = [NSString stringWithUTF8String:fields.display.c_str()];
            const bool group = fields.session.find("@chatroom") != std::string::npos;
            if (group) WCRContactNameRemember(who, nil, seen, nil, nil);
            else WCRContactNameRemember(who, nil, nil, seen, nil);
            NSString *preferred = WCRContactNamePreferred(who, seen);
            if (preferred.length > 0) fields.display = preferred.UTF8String;
        }
    }
    fields.time = FormatTime(xml);
    fields.content = TruncateUTF8(FirstTagValue(xml, {"content", "msgcontent"}), kMaxContentBytes);
    return fields;
}

static BOOL WCRTipContentEnabled(void) {
    id stored = [[NSUserDefaults standardUserDefaults]
        objectForKey:@"WCRefineMacRecallContentEnabled"];
    return stored ? [stored boolValue] : YES;
}

NSString *RenderTipText(const RevokeFields &fields) {
    NSString *name = StringFromUTF8(fields.display);
    NSString *time = StringFromUTF8(fields.time);
    NSString *wxid = StringFromUTF8(fields.userID);
    NSString *session = StringFromUTF8(fields.session);
    NSString *content = StringFromUTF8(fields.content);

    NSString *contentValue = @"";
    if (WCRTipContentEnabled() && content.length > 0) {
        contentValue = content.length > 20
            ? [[content substringToIndex:20] stringByAppendingString:@"..."]
            : content;
    }

    NSString *tpl = WCRRecallTipStoredTemplate();
    if (contentValue.length == 0) {
        // 内容被关闭或不可用时，含 {content} 的整行直接去掉，避免留下“撤回内容：”空尾巴。
        NSMutableArray<NSString *> *kept = [NSMutableArray array];
        for (NSString *line in [tpl componentsSeparatedByString:@"\n"]) {
            if ([line containsString:@"{content}"]) continue;
            [kept addObject:line];
        }
        tpl = [kept componentsJoinedByString:@"\n"];
    }

    NSDictionary<NSString *, NSString *> *vars = @{
        @"name": name ?: @"",
        @"time": time ?: @"",
        @"content": contentValue,
        @"wxid": wxid ?: @"",
        @"session": session ?: @"",
    };
    // 单次扫描替换，避免用户内容里的 {name} 等占位符被二次展开。
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
            [out appendString:[tpl substringWithRange:
                NSMakeRange(cursor, open.location - cursor)]];
        }
        NSRange close = [tpl rangeOfString:@"}"
                                   options:0
                                     range:NSMakeRange(NSMaxRange(open),
                                                       tpl.length - NSMaxRange(open))];
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
    // 去掉渲染后产生的纯空白行，灰色提示条不需要空行。
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        if ([line stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]].length == 0) {
            continue;
        }
        [lines addObject:line];
    }
    // 行合并后置入零宽哨兵（放在末尾不影响排版），供 hook 识别自己渲染的提示。
    return [NSString stringWithFormat:@"%@%@", [lines componentsJoinedByString:@"\n"],
            @(kTipSentinelUTF8)];
}

void CacheTip(const std::string &key, const std::string &tip) {
    std::lock_guard<std::mutex> lock(gTipCacheMutex);
    if (gTipCache.size() >= kMaxTipCacheSize) gTipCache.clear();
    gTipCache[key] = tip;
}

std::string CachedTip(const std::string &key) {
    std::lock_guard<std::mutex> lock(gTipCacheMutex);
    auto it = gTipCache.find(key);
    return it != gTipCache.end() ? it->second : std::string();
}

NSString *StringFromUTF8(const std::string &value) {
    return value.empty() ? @"" : [NSString stringWithUTF8String:value.c_str()] ?: @"";
}

void EnsureHistory(void) {
    dispatch_once(&gHistoryOnce, ^{
        gHistory = [NSMutableArray array];
    });
}

void RecordEvent(NSString *user,
                 NSString *userID,
                 NSString *groupID,
                 NSString *session,
                 NSString *time,
                 NSString *content,
                 NSString *originalTip,
                 uint64_t newMsgID) {
    EnsureHistory();
    NSMutableDictionary<NSString *, NSString *> *event = [@{
        @"user": user ?: @"",
        @"userID": userID ?: @"",
        @"groupID": groupID ?: @"",
        @"session": session ?: @"",
        @"time": time ?: @"",
        @"content": content ?: @"",
        @"originalTip": originalTip ?: @"",
        @"newMsgID": [NSString stringWithFormat:@"%llu", (unsigned long long)newMsgID],
        @"capturedAt": [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]],
    } mutableCopy];
    @synchronized (gHistory) {
        [gHistory insertObject:event atIndex:0];
        while (gHistory.count > kMaxHistoryCount) [gHistory removeLastObject];
    }
}

bool ShouldRecordUniqueEvent(const std::string &key) {
    std::lock_guard<std::mutex> lock(gSeenMutex);
    if (gSeenEvents.size() > 512) gSeenEvents.clear();
    return gSeenEvents.insert(key).second;
}

std::string EscapeXMLText(const std::string &value) {
    std::string out;
    out.reserve(value.size());
    for (unsigned char c : value) {
        switch (c) {
            case '&': out += "&amp;"; break;
            case '<': out += "&lt;"; break;
            case '>': out += "&gt;"; break;
            default: out.push_back(static_cast<char>(c)); break;
        }
    }
    return out;
}

// 匹配 <tag> 或 <tag attr="...">，跳过 <tagOther> 和自闭合 <tag/>。
// 返回内文起点；找不到时返回 npos。
size_t FindTagInnerStart(const std::string &xml, const char *tag, size_t from) {
    const std::string needle = std::string("<") + tag;
    size_t pos = from;
    while ((pos = xml.find(needle, pos)) != std::string::npos) {
        size_t after = pos + needle.size();
        if (after >= xml.size()) return std::string::npos;
        const char next = xml[after];
        if (next != '>' && next != ' ' && next != '\t' && next != '\n' &&
            next != '\r' && next != '/') {
            pos = after;
            continue;
        }
        size_t gt = xml.find('>', after);
        if (gt == std::string::npos) return std::string::npos;
        if (gt > after && xml[gt - 1] == '/') {
            pos = gt + 1;
            continue;
        }
        return gt + 1;
    }
    return std::string::npos;
}

bool ReplaceTagInner(std::string &xml, const char *tag, const std::string &escaped) {
    size_t inner = FindTagInnerStart(xml, tag, 0);
    if (inner == std::string::npos) return false;
    const std::string close = std::string("</") + tag + ">";
    size_t end = xml.find(close, inner);
    if (end == std::string::npos) return false;
    xml.replace(inner, end - inner, escaped);
    return true;
}

// 微信会把改写后的系统消息再解析一轮，这一轮常常只剩 <content> 里的提示，
// <replacemsg> 被丢掉。没有 revoketime 时解析器因此返回 0。
std::string PlainTipFromRevokeXML(const std::string &xml) {
    for (const char *tag : {"content", "msgcontent", "replacemsg"}) {
        const std::string close = std::string("</") + tag + ">";
        size_t from = 0;
        while (from < xml.size()) {
            size_t inner = FindTagInnerStart(xml, tag, from);
            if (inner == std::string::npos) break;
            size_t end = xml.find(close, inner);
            if (end == std::string::npos) break;
            std::string value = DecodeXMLEntities(Trim(StripCDATA(
                xml.substr(inner, end - inner))));
            if (!value.empty() && SlotAlreadyShowsTip(value)) return value;
            from = end + close.size();
        }
    }
    return "";
}

struct BuiltTip {
    bool selfRecall = false;
    uint64_t newMsgID = 0;
    std::string tip;
    RevokeFields fields;
};

void FillCapturedContent(RevokeFields &fields, uint64_t newMsgID) {
    if (!fields.content.empty() || newMsgID == 0) return;
    NSString *captured = WCRMessageCaptureContent(newMsgID);
    if (captured.length) {
        fields.content = TruncateUTF8(captured.UTF8String ?: "", kMaxContentBytes);
    }
    NSUInteger capturedType = WCRMessageCaptureType(newMsgID);
    if (fields.content.empty() && capturedType != 0 && capturedType != 1) {
        static const std::map<uint64_t, const char *> kTypeNames = {
            {3, "[图片]"}, {34, "[语音]"}, {42, "[名片]"}, {43, "[视频]"},
            {47, "[表情]"}, {48, "[位置]"}, {49, "[链接/文件]"}, {51, "[状态]"},
        };
        auto it = kTypeNames.find(capturedType);
        if (it != kTypeNames.end()) fields.content = it->second;
    }
}

BuiltTip BuildTipFromXML(const std::string &xml, void *message) {
    BuiltTip built;
    std::string originalTip = TagValue(xml, "replacemsg");
    built.selfRecall = IsSelfRecall(originalTip);
    std::string xmlNewMsgID = TagValue(xml, "newmsgid");
    if (!xmlNewMsgID.empty()) {
        built.newMsgID = strtoull(xmlNewMsgID.c_str(), nullptr, 10);
    }
    if (built.selfRecall) return built;
    built.fields = ParseRevokeFields(xml, originalTip, message);
    FillCapturedContent(built.fields, built.newMsgID);
    NSString *rendered = RenderTipText(built.fields);
    if (rendered.UTF8String) built.tip = rendered.UTF8String;
    return built;
}

// 常见成功路径在返回前已经把 <revokemsg> 里的 <content> 抄进展示字符串。
// 文档前面可能还有别的 <content>（外层 sysmsg），只改第一处会漏掉真正的展示标签。
void RewriteRevokeDisplayTags(std::string &xml, const std::string &tip) {
    if (tip.empty()) return;
    std::string escaped = EscapeXMLText(tip);
    auto rewrite = [&](std::string &region) {
        ReplaceTagInner(region, "content", escaped);
        ReplaceTagInner(region, "msgcontent", escaped);
        ReplaceTagInner(region, "replacemsg", escaped);
    };
    size_t open = xml.find("<revokemsg");
    if (open != std::string::npos) {
        size_t gt = xml.find('>', open);
        size_t close = xml.find("</revokemsg>", open);
        if (gt != std::string::npos && close != std::string::npos && close > gt) {
            std::string region = xml.substr(gt + 1, close - (gt + 1));
            rewrite(region);
            xml.replace(gt + 1, close - (gt + 1), region);
            return;
        }
    }
    rewrite(xml);
}

// 270135 的灰字不只在 +0x1D0。revoketime 路径还会把同一条文案赋给另外两份
// std::string。偏移为 0 的构建只写 revokeReplaceMsgOffset。
void AssignDisplayString(void *message, uint64_t offset, const std::string &tip) {
    if (!message || offset == 0 || tip.empty()) return;
    auto *slot = reinterpret_cast<std::string *>(
        reinterpret_cast<uint8_t *>(message) + offset);
    if (!IsAddressRangeReadable(slot, sizeof(*slot))) return;
    if (!SlotAlreadyShowsTip(*slot)) slot->assign(tip);
}

void PublishRecallTip(void *message, const std::string &tip) {
    AssignDisplayString(message, gProfile.revokeReplaceMsgOffset, tip);
    AssignDisplayString(message, gProfile.revokeDisplayCopyOffsetA, tip);
    AssignDisplayString(message, gProfile.revokeDisplayCopyOffsetB, tip);
}

void RememberTip(const BuiltTip &built, uint64_t newMsgID, const std::string &xmlSnapshot) {
    if (built.tip.empty()) return;
    std::string dedupKey = newMsgID != 0
        ? built.fields.session + "|" + std::to_string(newMsgID)
        : built.fields.session + "|xml:" + std::to_string(std::hash<std::string>{}(xmlSnapshot));
    CacheTip(dedupKey, built.tip);
    if (!ShouldRecordUniqueEvent(dedupKey)) return;
    RecordEvent(StringFromUTF8(built.fields.display),
                StringFromUTF8(built.fields.userID),
                StringFromUTF8(built.fields.groupID),
                StringFromUTF8(built.fields.session),
                StringFromUTF8(built.fields.time),
                StringFromUTF8(built.fields.content),
                StringFromUTF8(built.fields.originalTip),
                newMsgID);
    // 自己撤回在调用前就返回了。这里用完整捕获正文，不走灰字那 20 字截断。
    WCRRecallNotifyOnUniqueRecall(StringFromUTF8(built.fields.display),
                                  StringFromUTF8(built.fields.time),
                                  StringFromUTF8(built.fields.content),
                                  StringFromUTF8(built.fields.userID),
                                  StringFromUTF8(built.fields.session),
                                  newMsgID);
}

void ClearParserFlag(void *flag) {
    if (!flag || !IsAddressRangeReadable(flag, sizeof(uint8_t))) return;
    *static_cast<uint8_t *>(flag) = 0;
}

std::string CachedTipForRevoke(const std::string &xml, uint64_t id) {
    std::string session = TagValue(xml, "session");
    if (id != 0) {
        std::string cached = CachedTip(session + "|" + std::to_string(id));
        if (!cached.empty()) return cached;
    }
    std::string xmlID = TagValue(xml, "newmsgid");
    if (!xmlID.empty()) return CachedTip(session + "|" + xmlID);
    return "";
}

bool ZeroNewMsgID(void *message, uint64_t *fieldID) {
    if (!message || gProfile.revokeNewMsgIdOffset == 0) return false;
    auto *slot = reinterpret_cast<uint64_t *>(
        reinterpret_cast<uint8_t *>(message) + gProfile.revokeNewMsgIdOffset);
    if (!IsAddressRangeReadable(slot, sizeof(*slot))) return false;
    if (fieldID) *fieldID = *slot;
    *slot = 0;
    return true;
}

// 解析失败时仍把纯文本提示写进三份展示串，并让调用方跳过会清空灰字的回退。
bool PublishRecoveredTip(void *message,
                         std::string *xml,
                         void *flag,
                         const BuiltTip &built,
                         bool presetRevoke,
                         bool presetOurs) {
    if (!message || !xml || built.selfRecall) return false;
    std::string xmlSnapshot;
    try {
        xmlSnapshot = *xml;
    } catch (...) {
        return false;
    }
    if (!presetRevoke && !presetOurs && !LooksLikeRevokeXML(xmlSnapshot)) return false;

    uint64_t fieldID = 0;
    ZeroNewMsgID(message, &fieldID);
    uint64_t id = built.newMsgID != 0 ? built.newMsgID : fieldID;
    if (id == 0) {
        std::string xmlNewMsgID = TagValue(xmlSnapshot, "newmsgid");
        if (!xmlNewMsgID.empty()) id = strtoull(xmlNewMsgID.c_str(), nullptr, 10);
    }

    std::string tip = !presetOurs ? built.tip : "";
    if (tip.empty()) tip = CachedTipForRevoke(xmlSnapshot, id);
    if (tip.empty()) tip = PlainTipFromRevokeXML(xmlSnapshot);
    if (tip.empty()) return false;

    try {
        PublishRecallTip(message, tip);
        if (!presetOurs && !built.tip.empty()) RememberTip(built, id, xmlSnapshot);
        ClearParserFlag(flag);
    } catch (...) {
        return false;
    }
    return true;
}

bool HookedParseRevokeXML(void *message, std::string *xml, void *flag) {
    if (!gOriginalParseRevokeXML) return false;
    if (!gInstalled.load()) return gOriginalParseRevokeXML(message, xml, flag);

    BuiltTip built;
    bool presetRevoke = false;
    bool presetOurs = false;
    if (xml) {
        try {
            presetRevoke = LooksLikeRevokeXML(*xml);
            presetOurs = presetRevoke && LooksLikeOurTip(*xml);
            if (presetRevoke && !presetOurs) {
                built = BuildTipFromXML(*xml, message);
                if (!built.selfRecall && !built.tip.empty()) {
                    // 解析器的子调用可能在返回前就把 <content> 抄进展示串。
                    RewriteRevokeDisplayTags(*xml, built.tip);
                }
            }
        } catch (...) {
            // 改写失败就让原解析器按原 XML 走，下面仍会兜底防撤回。
        }
    }

    bool result = gOriginalParseRevokeXML(message, xml, flag);
    if (!message || !xml) return result;
    // 没有 revoketime 时，二次解析若丢掉 <replacemsg>，解析器返回 0。
    // 调用方接着会走 FormatLinkInfo，把灰字清掉。这里先把纯文本提示补回去。
    if (!result) {
        return PublishRecoveredTip(message, xml, flag, built, presetRevoke, presetOurs)
            ? true
            : result;
    }

    @autoreleasepool {
        try {
            std::string xmlSnapshot = *xml;
            if (!presetRevoke && !LooksLikeRevokeXML(xmlSnapshot)) return result;

            const auto *base = reinterpret_cast<const uint8_t *>(message);
            auto *newMsgID = reinterpret_cast<uint64_t *>(const_cast<uint8_t *>(
                base + gProfile.revokeNewMsgIdOffset));
            auto *replaceMsg = reinterpret_cast<std::string *>(const_cast<uint8_t *>(
                base + gProfile.revokeReplaceMsgOffset));
            if (!IsAddressRangeReadable(newMsgID, sizeof(*newMsgID)) ||
                !IsAddressRangeReadable(replaceMsg, sizeof(*replaceMsg))) {
                return result;
            }

            // 防撤回的兜底：无论下面走哪条分支，都不能让微信拿到有效的
            // newMsgID 去执行原生撤回。先留一份，XML 没有 newmsgid 时用它反查原文。
            uint64_t fieldID = *newMsgID;
            *newMsgID = 0;
            uint64_t id = built.newMsgID != 0 ? built.newMsgID : fieldID;
            if (id == 0) {
                std::string xmlNewMsgID = TagValue(xmlSnapshot, "newmsgid");
                if (!xmlNewMsgID.empty()) id = strtoull(xmlNewMsgID.c_str(), nullptr, 10);
            }

            if (built.selfRecall) return result;

            // 二次解析：提示文本已经在 XML 里。只把文案补回三份展示串。
            // 不改这个对象的 +0x100/+0x114：那是聊天消息的时间，解析参数在 +0x288
            // 存 revoketime。写错对象会让灰字不再出现，防撤回（newMsgID 置零）却还在。
            if (presetOurs || LooksLikeOurTip(xmlSnapshot) || LooksLikeOurTip(*replaceMsg)) {
                if (!presetOurs && !built.tip.empty()) {
                    PublishRecallTip(message, built.tip);
                    RememberTip(built, id, xmlSnapshot);
                    ClearParserFlag(flag);
                } else {
                    std::string recovered = CachedTipForRevoke(xmlSnapshot, id);
                    if (recovered.empty()) recovered = PlainTipFromRevokeXML(xmlSnapshot);
                    if (!recovered.empty()) {
                        PublishRecallTip(message, recovered);
                        ClearParserFlag(flag);
                    }
                }
                return result;
            }

            if (built.tip.empty()) {
                built = BuildTipFromXML(xmlSnapshot, message);
                if (built.newMsgID == 0) built.newMsgID = id;
                if (id == 0) id = built.newMsgID;
            }
            if (built.selfRecall || built.tip.empty()) return result;
            PublishRecallTip(message, built.tip);
            RememberTip(built, id, xmlSnapshot);
            ClearParserFlag(flag);
        } catch (...) {
            // A malformed recall event must never break WeChat's parser.
        }
    }
    return result;
}

}  // namespace

NSString *WCRRecallTipDefaultTemplate(void) {
    return @"⚠️ 已拦截一条撤回消息 ⚠️\n撤回人：{name}\n撤回时间：{time}\n撤回内容：{content}";
}

NSString *WCRRecallTipStoredTemplate(void) {
    @autoreleasepool {
        NSString *stored = [[NSUserDefaults standardUserDefaults]
            stringForKey:@"WCRefineMacRecallTipTemplate"];
        NSString *trimmed = [stored stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        if (trimmed.length == 0 || trimmed.length > kMaxTemplateBytes) {
            return WCRRecallTipDefaultTemplate();
        }
        return trimmed;
    }
}

void WCRRecallTipSetStoredTemplate(NSString *templateString) {
    @autoreleasepool {
        NSString *trimmed = [templateString stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        if (trimmed.length == 0 || trimmed.length > kMaxTemplateBytes) {
            [[NSUserDefaults standardUserDefaults]
                removeObjectForKey:@"WCRefineMacRecallTipTemplate"];
            return;
        }
        [[NSUserDefaults standardUserDefaults] setObject:trimmed
                                                  forKey:@"WCRefineMacRecallTipTemplate"];
    }
}

BOOL WCRRecallTipInstall(const WCRPatchProfile *profile, NSError **error) {
    if (gInstalled.load()) return YES;
    if (!profile || profile->revokeParserAddress == 0 ||
        profile->revokeNewMsgIdOffset == 0 || profile->revokeReplaceMsgOffset == 0) {
        if (error) *error = WCRTipError(@"当前微信构建没有撤回提示所需的函数信息");
        return NO;
    }

    uintptr_t slide = 0;
    if (!FindLoadedWeChatDylib(&slide)) {
        if (error) *error = WCRTipError(@"wechat.dylib 尚未加载");
        return NO;
    }
    WCRTipDebug("tip install: slide=%lx entry=%lx\n", (unsigned long)slide, (unsigned long)(slide + profile->revokeParserAddress));

    uint8_t *entry = reinterpret_cast<uint8_t *>(slide + profile->revokeParserAddress);
    if (!IsAddressRangeReadable(entry, kEntryBytes) ||
        memcmp(entry, profile->revokePrologue, kEntryBytes) != 0) {
        if (error) *error = WCRTipError(@"撤回解析函数入口字节不匹配，拒绝安装提示 Hook");
        return NO;
    }

    WCRTipDebug("tip install: entry prologue readable=%d\n", IsAddressRangeReadable(entry, kEntryBytes) ? 1 : 0);
    uint8_t *guard = reinterpret_cast<uint8_t *>(slide + profile->patchAddress);
    if (!IsAddressRangeReadable(guard, sizeof(profile->expectedBytes)) ||
        memcmp(guard, profile->expectedBytes, sizeof(profile->expectedBytes)) != 0) {
        if (error) *error = WCRTipError(@"请先恢复静默补丁，再安装撤回提示");
        return NO;
    }

    WCRTipDebug("tip install: guard readable=%d\n", IsAddressRangeReadable(guard, 4) ? 1 : 0);
    void *trampoline = gTrampoline;
    if (!trampoline) {
        trampoline = mmap(nullptr, kTrampolineBytes, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANON, -1, 0);
        if (trampoline == MAP_FAILED) {
            if (error) *error = WCRTipError(@"无法分配撤回提示 trampoline");
            return NO;
        }
        WCRTipDebug("tip install: trampoline=%p\n", trampoline);

        uint8_t *trampolineBytes = static_cast<uint8_t *>(trampoline);
        memcpy(trampolineBytes, entry, kEntryBytes);
        uint32_t tailHead[2] = {0x58000050u, 0xD61F0200u}; // ldr x16,#8; br x16
        memcpy(trampolineBytes + 16, tailHead, sizeof(tailHead));
        uint64_t continueAddress = reinterpret_cast<uint64_t>(entry + kEntryBytes);
        memcpy(trampolineBytes + 24, &continueAddress, sizeof(continueAddress));
        sys_icache_invalidate(trampolineBytes, kTrampolineBytes);
        WCRTipDebug("tip install: trampoline written\n");
        if (mprotect(trampoline, kTrampolineBytes, PROT_READ | PROT_EXEC) != 0) {
            munmap(trampoline, kTrampolineBytes);
            if (error) *error = WCRTipError(@"无法将撤回提示 trampoline 设为可执行");
            return NO;
        }
        // 先发布跳板，再改写入口；卸载时也保留它，供在途线程安全返回原函数。
        gTrampoline = trampoline;
        gOriginalParseRevokeXML = reinterpret_cast<ParseRevokeXMLFn>(trampoline);
    }

    uint8_t patch[kEntryBytes] = {};
    uint32_t patchHead[2] = {0x58000050u, 0xD61F0200u}; // ldr x16,#8; br x16
    memcpy(patch, patchHead, sizeof(patchHead));
    uint64_t hookAddress = reinterpret_cast<uint64_t>(&HookedParseRevokeXML);
    memcpy(patch + 8, &hookAddress, sizeof(hookAddress));

    memcpy(gSavedEntry, entry, kEntryBytes);
    gEntryAddress = entry;
    gProfile = *profile;

    WCRTipDebug("tip install: patching entry\n");
    if (!WriteProcessBytes(entry, patch, kEntryBytes)) {
        if (error) *error = WCRTipError(@"无法写入撤回提示 Hook");
        return NO;
    }

    gInstalled.store(true);
    WCRTipDebug("tip install: done\n");
    return YES;
}

BOOL WCRRecallTipUninstall(NSError **error) {
    if (!gInstalled.load()) return YES;
    if (!gEntryAddress || !WriteProcessBytes(gEntryAddress, gSavedEntry, kEntryBytes)) {
        if (error) *error = WCRTipError(@"无法恢复撤回解析函数入口");
        return NO;
    }

    gInstalled.store(false);
    // 跳板保留到进程结束：可能仍有线程停在 Hook 内，不能在这里 munmap。
    return YES;
}

BOOL WCRRecallTipIsInstalled(void) {
    return gInstalled.load();
}

NSArray<NSDictionary<NSString *, NSString *> *> *WCRRecallTipRecentEvents(void) {
    EnsureHistory();
    @synchronized (gHistory) {
        return [gHistory copy];
    }
}

void WCRRecallTipClearRecentEvents(void) {
    EnsureHistory();
    @synchronized (gHistory) {
        [gHistory removeAllObjects];
    }
}
