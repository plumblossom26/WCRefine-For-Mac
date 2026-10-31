#import "WCRGroupLeaveMonitor.h"
#import "WCRRecallNotify.h"
#import "WCRContactName.h"

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>

#include <algorithm>
#include <cctype>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// 退群监控以 WCRMessageCapture 的观察者身份复用收口 Hook（该 Hook 由消息
// 捕获模块独占安装，观察者在 Hook 未装前注册也安全）。观察者契约：同步、
// 快速、不得抛异常。本模块在观察者回调里自行做类型门控与防御性读取。
//
// 群系统事件经过同一收口时有三种形态：10000 是灰字提示（「张三退出了群聊」），
// 10002 是原始 sysmsg XML（delchatroommember / sysmsgtemplate），49 是部分群
// 机器人/群助手发出的退群通知 appmsg。只认前两种时，实测的「检测到 F 退出本群」
// 会直接被丢掉。内容仍必须像退群，普通聊天和撤回 XML 排除。
//
// 认出来之后改写正文：有用户名时换成和进群提示一样的 sysmsgtemplate，
// {name} 落在 link_profile 上，点群昵称打开资料页。49 的 appmsg 外壳无法显示
// 资料链接，因此改成 10000 系统提示，并把 fromUsr 归一为群 ID。没有用户名就写
// 纯文本。零宽哨兵避免同一条消息再次经过收口时把提示套进提示。
constexpr uint32_t kSystemTipType = 10000;
constexpr uint32_t kSystemCommandType = 10002;
constexpr uint32_t kAppMessageType = 49;
// fromUsr，与 WCROriginalID 同一套字段。部分 XML 落在这里
// 而不是正文；只在该字段以 '<' 开头时才当作退群载荷。
constexpr uint64_t kCalibratedFromOffset = 0x18;
constexpr size_t kMaxContentBytes = 65536;
constexpr size_t kMaxScanBytes = 0x200;
constexpr char kChatroomSuffix[] = "@chatroom";
constexpr size_t kChatroomSuffixLength = 9;

NSString *const kTemplateDefaultsKey = @"WCRefineMacGroupLeaveTemplate";
constexpr size_t kMaxTemplateBytes = 1000;
// 与撤回提示同一枚零宽字符。已经改写过的正文带上它，第二次经过收口就跳过。
constexpr const char *kLeaveSentinel = "\xE2\x80\x8B";

namespace {

std::atomic_bool gEnabled(false);
uint64_t gTypeOffset = 0;
uint64_t gContentOffset = 0;
uint64_t gCreateTimeSecOffset = 0;

os_log_t WCRLeaveLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.wcrefine.mac", "plugin");
    });
    return log;
}

NSError *WCRLeaveError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMac.GroupLeave"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"退群监控错误"}];
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

std::string FirstTagValue(const std::string &xml, const std::vector<std::string> &tags) {
    for (const auto &tag : tags) {
        std::string value = TagValue(xml, tag);
        if (!value.empty()) return value;
    }
    return "";
}

void TagAllValues(const std::string &xml, const std::string &tag, std::vector<std::string> *out) {
    std::string open = "<" + tag + ">";
    std::string close = "</" + tag + ">";
    size_t cursor = 0;
    while (true) {
        size_t start = xml.find(open, cursor);
        if (start == std::string::npos) break;
        start += open.size();
        size_t end = xml.find(close, start);
        if (end == std::string::npos) break;
        std::string value = DecodeXMLEntities(Trim(StripCDATA(xml.substr(start, end - start))));
        if (!value.empty()) out->push_back(value);
        cursor = end + close.size();
    }
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
    if (!data || length == 0 || length > kMaxContentBytes || !IsAddressRangeReadable(data, length)) {
        return false;
    }
    out.assign(data, length);
    return true;
}

bool EndsWithChatroom(const std::string &value) {
    return value.size() > kChatroomSuffixLength &&
           value.compare(value.size() - kChatroomSuffixLength,
                         kChatroomSuffixLength, kChatroomSuffix) == 0;
}

std::string FindChatroomIDInMessage(const void *message) {
    const auto *base = reinterpret_cast<const uint8_t *>(message);
    for (size_t offset = 0; offset < kMaxScanBytes; offset += 8) {
        std::string value;
        if (!ReadLibcppStringAt(base + offset, value)) continue;
        if (EndsWithChatroom(value)) return value;
    }
    return "";
}

#pragma mark - 事件解析

struct Member {
    std::string id;
    std::string name;
};

struct GroupLeaveEvent {
    std::string who;
    std::string whoID;
    std::string groupID;
    std::string kind;       // quit / kicked / unknown
    std::string timeText;
    std::vector<Member> members;
};

bool ContainsAny(const std::string &text, const char *const *markers, size_t count, size_t *positionOut) {
    for (size_t i = 0; i < count; ++i) {
        size_t position = text.find(markers[i]);
        if (position != std::string::npos) {
            if (positionOut) *positionOut = position;
            return true;
        }
    }
    return false;
}

const char *const kQuitMarkers[] = {"退出了群聊", "退出群聊", "left the group"};
const char *const kKickMarkers[] = {"移出了群聊", "被移出群聊", "移出群聊"};
const char *const kAppLeaveTitleMarkers[] = {
    "退出本群", "退出了本群", "退群人员", "退群成员", "退出了群聊", "移出了群聊", "退出群聊"
};
const char *const kAppLeaveDesMarkers[] = {"退群时间", "退出时间", "移出时间"};

bool LooksLikeAppMessageLeave(const std::string &content) {
    if (content.find("revokemsg") != std::string::npos) return false;
    if (content.find("<appmsg") == std::string::npos) return false;
    std::string title = TagValue(content, "title");
    if (ContainsAny(title, kAppLeaveTitleMarkers,
                    sizeof(kAppLeaveTitleMarkers) / sizeof(kAppLeaveTitleMarkers[0]), nullptr)) {
        return true;
    }
    std::string des = TagValue(content, "des");
    return ContainsAny(des, kAppLeaveDesMarkers,
                       sizeof(kAppLeaveDesMarkers) / sizeof(kAppLeaveDesMarkers[0]), nullptr);
}

bool LooksLikeGroupLeave(const std::string &content) {
    // 撤回 XML 会原样嵌回被撤回的文本。一句「退出了群聊」被撤回时不能记成退群。
    if (content.find("revokemsg") != std::string::npos) return false;
    if (content.find("delchatroommember") != std::string::npos) return true;
    if (LooksLikeAppMessageLeave(content)) return true;
    return ContainsAny(content, kQuitMarkers, sizeof(kQuitMarkers) / sizeof(kQuitMarkers[0]), nullptr) ||
           ContainsAny(content, kKickMarkers, sizeof(kKickMarkers) / sizeof(kKickMarkers[0]), nullptr);
}

bool HasMemberTable(const std::string &content) {
    return content.find("<member>") != std::string::npos ||
           content.find("<username>") != std::string::npos;
}

std::string GroupIDFromPayload(const std::string &content, void *message) {
    const char *tags[] = {"session", "roomname", "chatroomname", "fromusername"};
    for (const char *tag : tags) {
        std::string value = TagValue(content, tag);
        if (EndsWithChatroom(value)) return value;
    }
    return FindChatroomIDInMessage(message);
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

std::string DisplayNameForSelf(const std::string &who) {
    // “你退出了群聊 / 你被移出群聊 / You left …” 一律归为本人事件。
    if (who.rfind("你", 0) == 0 || who.rfind("You", 0) == 0 || who.rfind("you", 0) == 0) {
        return "我";
    }
    return who;
}

std::string PlainDisplayName(const std::string &content, size_t marker) {
    std::string prefix = content.substr(0, marker);
    size_t line = prefix.rfind('\n');
    if (line != std::string::npos) prefix = prefix.substr(line + 1);
    prefix = StripOuterQuotes(Trim(prefix));
    // 标记落在 XML / 模板（$username$）里时，前缀不是人名。
    if (prefix.empty() || prefix.size() > 80 ||
        prefix.find('<') != std::string::npos ||
        prefix.find('>') != std::string::npos ||
        prefix.find('$') != std::string::npos) {
        return "未知成员";
    }
    std::string who = DisplayNameForSelf(prefix);
    return who.empty() ? std::string("未知成员") : who;
}

std::string StripNoticePunctuation(std::string value) {
    value = Trim(value);
    while (!value.empty()) {
        if (value.back() == '!' || value.back() == '.' || value.back() == ',' || value.back() == ':') {
            value.pop_back();
            value = Trim(value);
            continue;
        }
        if (value.size() >= 3) {
            std::string suffix = value.substr(value.size() - 3);
            if (suffix == "！" || suffix == "。" || suffix == "，" || suffix == "：") {
                value.resize(value.size() - 3);
                value = Trim(value);
                continue;
            }
        }
        break;
    }
    return StripOuterQuotes(value);
}

std::string NameFromAppMessageLeave(const std::string &content) {
    std::string title = TagValue(content, "title");
    if (title.empty()) return "";

    // 「退群人员：昵称」「退群成员: 昵称」
    for (const char *prefix : {"退群人员", "退群成员"}) {
        size_t start = title.find(prefix);
        if (start == std::string::npos) continue;
        size_t colon = title.find_first_of(":：", start + strlen(prefix));
        if (colon != std::string::npos) {
            return StripNoticePunctuation(title.substr(colon + 1));
        }
    }

    // 「检测到 F 退出本群！」以及「F 退出了群聊」等 appmsg 标题。
    const char *markers[] = {"退出本群", "退出了本群", "退出了群聊", "移出了群聊", "退出群聊"};
    for (const char *marker : markers) {
        size_t position = title.find(marker);
        if (position == std::string::npos) continue;
        std::string name = title.substr(0, position);
        size_t detected = name.find("检测到");
        if (detected != std::string::npos) name = name.substr(detected + strlen("检测到"));
        return StripNoticePunctuation(name);
    }
    return "";
}

std::string ValueAfterLabel(const std::string &text, const std::vector<std::string> &labels) {
    for (const auto &label : labels) {
        size_t position = text.find(label);
        if (position == std::string::npos) continue;
        position += label.size();
        while (position < text.size() &&
               (text[position] == ' ' || text[position] == '\t' || text[position] == '\r' ||
                text[position] == '\n')) {
            position++;
        }
        size_t end = text.find_first_of("\r\n", position);
        std::string value = text.substr(position,
                                        end == std::string::npos ? std::string::npos : end - position);
        value = StripNoticePunctuation(value);
        if (!value.empty()) return value;
    }
    return "";
}

std::string AccountFromAppMessageLeave(const std::string &content) {
    std::string des = TagValue(content, "des");
    return ValueAfterLabel(des, {"账号：", "账号:", "微信号：", "微信号:", "ID：", "ID:"});
}

// 自动样式仍是群名片优先于微信昵称。退群卡片曾把联系人显示名（Dollar Max）写成链文，
// 群昵称（92-二手良民-渝）落在 displayname 里。指定样式才走统一名称解析。
std::string PreferredMemberName(const std::string &block) {
    std::string card = FirstTagValue(block, {"displayname", "displayName", "groupnickname",
                                              "groupNickname"});
    std::string nick = FirstTagValue(block, {"nickname", "nickName"});
    std::string id = TagValue(block, "username");
    @autoreleasepool {
        NSString *who = id.empty() ? nil : [NSString stringWithUTF8String:id.c_str()];
        NSString *cardText = card.empty() ? nil : [NSString stringWithUTF8String:card.c_str()];
        NSString *nickText = nick.empty() ? nil : [NSString stringWithUTF8String:nick.c_str()];
        WCRContactNameRemember(who, nil, cardText, nickText, nil);
        if (WCRContactNameCurrentStyle() != WCRContactNameStyleAuto) {
            NSString *resolved = WCRContactNameResolve(who, cardText, nickText, nil);
            if (resolved.length > 0) {
                const char *raw = resolved.UTF8String;
                if (raw && raw[0]) return raw;
            }
        }
    }
    if (!card.empty()) return card;
    return nick;
}

void CollectMembers(const std::string &xml,
                    const std::string &groupID,
                    std::vector<Member> *out) {
    size_t cursor = 0;
    while (true) {
        size_t blockStart = xml.find("<member>", cursor);
        if (blockStart == std::string::npos) break;
        size_t blockEnd = xml.find("</member>", blockStart);
        if (blockEnd == std::string::npos) break;
        std::string block = xml.substr(blockStart, blockEnd - blockStart);
        cursor = blockEnd + 9;
        std::string id = TagValue(block, "username");
        if (id.empty() || id == groupID || EndsWithChatroom(id)) continue;
        std::string name = PreferredMemberName(block);
        out->push_back({id, name.empty() ? id : name});
    }

    if (out->empty()) {
        std::vector<std::string> ids;
        TagAllValues(xml, "username", &ids);
        for (const auto &id : ids) {
            if (id == groupID || EndsWithChatroom(id)) continue;
            out->push_back({id, id});
        }
    }
}

std::string JoinWithSeparator(const std::vector<std::string> &values) {
    std::string joined;
    for (const auto &value : values) {
        if (!joined.empty()) joined += "、";
        joined += value;
    }
    return joined;
}

std::string FormatEpoch(double epoch) {
    @autoreleasepool {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        NSString *text = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:epoch]] ?: @"";
        return text.UTF8String ?: "";
    }
}

double EpochFromPayload(const std::string &content, void *message) {
    std::string rawTime = TagValue(content, "createtime");
    if (!rawTime.empty()) {
        double epoch = strtod(rawTime.c_str(), nullptr);
        if (epoch > 1000000000000.0) epoch /= 1000.0;
        if (epoch > 0) return epoch;
    }
    // XML 没有 createtime 时用聊天消息自己的秒（270135 在 +0x114）。
    // 偏移为 0 的构建不猜，退回当前时间。
    if (message && gCreateTimeSecOffset != 0) {
        const auto *base = reinterpret_cast<const uint8_t *>(message);
        uint32_t seconds = 0;
        if (IsAddressRangeReadable(base + gCreateTimeSecOffset, sizeof(seconds))) {
            memcpy(&seconds, base + gCreateTimeSecOffset, sizeof(seconds));
            if (seconds > 0) return seconds;
        }
    }
    return [[NSDate date] timeIntervalSince1970];
}

bool ParseGroupLeaveEvent(const std::string &content, void *message, GroupLeaveEvent *out) {
    if (!LooksLikeGroupLeave(content)) return false;
    bool appMessage = content.find("<appmsg") != std::string::npos;

    // 群 ID：XML 的 session/roomname，其次在消息对象上扫描 @chatroom。
    out->groupID = GroupIDFromPayload(content, message);

    size_t kickPosition = 0;
    size_t quitPosition = 0;
    bool kicked = ContainsAny(content, kKickMarkers, sizeof(kKickMarkers) / sizeof(kKickMarkers[0]), &kickPosition);
    bool quit = ContainsAny(content, kQuitMarkers, sizeof(kQuitMarkers) / sizeof(kQuitMarkers[0]), &quitPosition);
    if (appMessage) {
        out->kind = "quit";
        Member member;
        member.name = NameFromAppMessageLeave(content);
        member.id = AccountFromAppMessageLeave(content);
        if (!member.name.empty() || !member.id.empty()) out->members.push_back(member);
    } else if (kicked) {
        out->kind = "kicked";
    } else if (quit) {
        out->kind = "quit";
    } else {
        out->kind = "unknown";
    }

    // 有成员表时用人名，避免把整段 sysmsgtemplate 当成「谁」。
    if (!appMessage && HasMemberTable(content)) {
        CollectMembers(content, out->groupID, &out->members);
    } else if (!appMessage && (kicked || quit)) {
        size_t marker = kicked && quit ? MIN(kickPosition, quitPosition) : (kicked ? kickPosition : quitPosition);
        Member member;
        member.name = PlainDisplayName(content, marker);
        member.id = WxidFromText(content);
        out->members.push_back(member);
    }
    if (out->members.empty()) {
        out->who = "未知成员";
    } else {
        std::vector<std::string> ids;
        std::vector<std::string> names;
        ids.reserve(out->members.size());
        names.reserve(out->members.size());
        for (const auto &member : out->members) {
            if (!member.id.empty()) ids.push_back(member.id);
            names.push_back(member.name.empty() ? member.id : member.name);
        }
        out->whoID = JoinWithSeparator(ids);
        out->who = names.empty() ? std::string("未知成员") : JoinWithSeparator(names);
    }

    double epoch = EpochFromPayload(content, message);
    out->timeText = FormatEpoch(epoch);
    return true;
}

NSString *OwnedUTF8(const std::string &value) {
    if (value.empty()) return @"";
    NSString *text = [[NSString alloc] initWithBytes:value.data()
                                              length:value.size()
                                            encoding:NSUTF8StringEncoding];
    return text ?: @"";
}

#pragma mark - 灰字通知

bool AlreadyRewritten(const std::string &text) {
    return text.find(kLeaveSentinel) != std::string::npos;
}

bool ValidToken(const std::string &token) {
    if (token.empty() || token.size() > 32) return false;
    for (unsigned char c : token) {
        if (!std::isalnum(c) && c != '_') return false;
    }
    return true;
}

bool MemberLinkable(const Member &member) {
    return !member.id.empty() && !EndsWithChatroom(member.id);
}

std::string EscapeCDATA(const std::string &value) {
    std::string out;
    out.reserve(value.size());
    size_t cursor = 0;
    while (true) {
        size_t pos = value.find("]]>", cursor);
        if (pos == std::string::npos) {
            out.append(value, cursor, std::string::npos);
            break;
        }
        out.append(value, cursor, pos - cursor);
        out += "]]]]><![CDATA[>";
        cursor = pos + 3;
    }
    return out;
}

std::string AttributeNear(const std::string &xml, size_t anchor, const char *key) {
    size_t begin = anchor > 180 ? anchor - 180 : 0;
    size_t end = std::min(xml.size(), anchor + 180);
    std::string slice = xml.substr(begin, end - begin);
    std::string pattern = std::string(key) + "=\"";
    size_t pos = slice.find(pattern);
    if (pos == std::string::npos) return "";
    pos += pattern.size();
    size_t quote = slice.find('"', pos);
    if (quote == std::string::npos) return "";
    return slice.substr(pos, quote - pos);
}

std::string ProfileLinkToken(const std::string &xml) {
    size_t pos = 0;
    while ((pos = xml.find("link_profile", pos)) != std::string::npos) {
        std::string name = AttributeNear(xml, pos, "name");
        if (ValidToken(name)) return name;
        pos += 12;
    }
    pos = 0;
    while ((pos = xml.find('$', pos)) != std::string::npos) {
        size_t end = xml.find('$', pos + 1);
        if (end == std::string::npos || end - pos > 40) {
            pos++;
            continue;
        }
        std::string name = xml.substr(pos + 1, end - pos - 1);
        if (ValidToken(name)) return name;
        pos = end + 1;
    }
    return "";
}

// 单次扫描替换，用户填进 {time} 的正文里如果再出现 {name} 不会被展开。
std::string RenderLeaveTemplate(const std::string &name,
                                const std::string &timeText,
                                const std::string &wxid,
                                const std::string &groupID,
                                bool appendSentinel) {
    @autoreleasepool {
        NSString *tpl = WCRGroupLeaveStoredTemplate();
        NSDictionary<NSString *, NSString *> *vars = @{
            @"name": OwnedUTF8(name),
            @"time": OwnedUTF8(timeText),
            @"wxid": OwnedUTF8(wxid),
            @"group": OwnedUTF8(groupID),
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
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
            if ([line stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]].length == 0) {
                continue;
            }
            [lines addObject:line];
        }
        NSString *full = [lines componentsJoinedByString:@"\n"];
        if (appendSentinel) {
            NSString *sentinel = [NSString stringWithUTF8String:kLeaveSentinel] ?: @"";
            full = [full stringByAppendingString:sentinel];
        }
        NSUInteger length = [full lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        const char *bytes = full.UTF8String;
        if (!bytes || length == NSNotFound) return "";
        return std::string(bytes, length);
    }
}

bool SetTagCDATA(std::string *xml, const char *tag, const std::string &body) {
    std::string openPrefix = std::string("<") + tag;
    std::string close = std::string("</") + tag + ">";
    size_t open = xml->find(openPrefix);
    if (open == std::string::npos) return false;
    size_t after = open + openPrefix.size();
    if (after < xml->size()) {
        char next = (*xml)[after];
        if (next != '>' && next != ' ' && next != '\t' && next != '\n' && next != '\r' && next != '/') {
            return false;
        }
    }
    size_t gt = xml->find('>', open);
    if (gt == std::string::npos) return false;
    size_t end = xml->find(close, gt);
    if (end == std::string::npos) return false;
    xml->replace(gt + 1, end - (gt + 1), "<![CDATA[" + EscapeCDATA(body) + "]]>");
    return true;
}

bool ReplaceMatchingTag(std::string *xml, const char *tag, const std::string &body) {
    std::string openPrefix = std::string("<") + tag;
    std::string close = std::string("</") + tag + ">";
    size_t cursor = 0;
    while (cursor < xml->size()) {
        size_t open = xml->find(openPrefix, cursor);
        if (open == std::string::npos) return false;
        size_t after = open + openPrefix.size();
        if (after < xml->size()) {
            char next = (*xml)[after];
            if (next != '>' && next != ' ' && next != '\t' && next != '\n' && next != '\r' && next != '/') {
                cursor = after;
                continue;
            }
        }
        size_t gt = xml->find('>', open);
        if (gt == std::string::npos) return false;
        size_t end = xml->find(close, gt);
        if (end == std::string::npos) return false;
        std::string inner = xml->substr(gt + 1, end - (gt + 1));
        bool matches = inner.find('$') != std::string::npos || LooksLikeGroupLeave(inner);
        if (!matches) {
            cursor = end + close.size();
            continue;
        }
        std::string cdata = "<![CDATA[" + EscapeCDATA(body) + "]]>";
        xml->replace(gt + 1, end - (gt + 1), cdata);
        return true;
    }
    return false;
}

void ApplyPreferredNicknames(std::string *xml) {
    std::string rebuilt;
    size_t last = 0;
    size_t cursor = 0;
    bool changed = false;
    while (true) {
        size_t blockStart = xml->find("<member>", cursor);
        if (blockStart == std::string::npos) break;
        size_t blockEnd = xml->find("</member>", blockStart);
        if (blockEnd == std::string::npos) break;
        std::string block = xml->substr(blockStart, blockEnd - blockStart);
        std::string preferred = PreferredMemberName(block);
        if (!preferred.empty()) {
            std::string updated = block;
            // 资料链接显示的是 <nickname>。群名片在 displayname 时要写进这个标签，
            // 点开看到的才是群昵称，不是微信昵称。
            if (!SetTagCDATA(&updated, "nickname", preferred)) {
                updated += "<nickname><![CDATA[" + EscapeCDATA(preferred) + "]]></nickname>";
            }
            rebuilt.append(*xml, last, blockStart - last);
            rebuilt += updated;
            last = blockEnd;
            changed = true;
        }
        cursor = blockEnd + 9;
    }
    if (changed) {
        rebuilt.append(*xml, last, std::string::npos);
        *xml = rebuilt;
    }
}

std::string MemberListXML(const std::vector<Member> &members) {
    std::string xml;
    for (const auto &member : members) {
        if (!MemberLinkable(member)) continue;
        std::string name = member.name.empty() ? member.id : member.name;
        xml += "<member><username><![CDATA[" + EscapeCDATA(member.id) +
               "]]></username><nickname><![CDATA[" + EscapeCDATA(name) +
               "]]></nickname></member>";
    }
    return xml;
}

std::string BuildProfileSysmsg(const std::string &body,
                               const std::string &token,
                               const std::vector<Member> &members) {
    return "<sysmsg type=\"sysmsgtemplate\"><sysmsgtemplate>"
           "<content_template type=\"tmpl_type_profile\">"
           "<plain><![CDATA[]]></plain>"
           "<template><![CDATA[" + EscapeCDATA(body) + "]]></template>"
           "<link_list><link name=\"" + token + "\" type=\"link_profile\"><memberlist>" +
           MemberListXML(members) +
           "</memberlist></link></link_list>"
           "</content_template></sysmsgtemplate></sysmsg>";
}

void InjectProfileLink(std::string *xml,
                       const std::string &token,
                       const std::vector<Member> &members) {
    if (xml->find("link_profile") != std::string::npos) return;
    std::string link = "<link name=\"" + token + "\" type=\"link_profile\"><memberlist>" +
                       MemberListXML(members) + "</memberlist></link>";
    size_t listEnd = xml->find("</link_list>");
    if (listEnd != std::string::npos) {
        xml->insert(listEnd, link);
        return;
    }
    std::string list = "<link_list>" + link + "</link_list>";
    const char *anchors[] = {"</content_template>", "</sysmsgtemplate>", "</sysmsg>"};
    for (const char *anchor : anchors) {
        size_t pos = xml->find(anchor);
        if (pos != std::string::npos) {
            xml->insert(pos, list);
            return;
        }
    }
    *xml += list;
}

std::string EnsureSessionPrefix(const std::string &xml, const std::string &groupID) {
    if (groupID.empty()) return xml;
    std::string prefix = groupID + ":";
    if (xml.rfind(prefix, 0) == 0) return xml;
    return groupID + ":\n" + xml;
}

std::string RenderedPayload(const std::string &content, const GroupLeaveEvent &event) {
    std::string token;
    bool canLink = false;
    for (const auto &member : event.members) {
        if (MemberLinkable(member)) canLink = true;
    }
    if (canLink) {
        token = ProfileLinkToken(content);
        if (!ValidToken(token)) token = "leaver";
    }
    std::string nameForTemplate = canLink ? ("$" + token + "$") : event.who;
    std::string body = RenderLeaveTemplate(nameForTemplate, event.timeText, event.whoID,
                                           event.groupID, true);
    if (body.empty()) return content;

    // 49 appmsg 的卡片外壳没有 link_profile 渲染能力。把正文换成微信进群提示
    // 同款的 sysmsgtemplate，并由调用方把消息类型改成 10000，群昵称才能点开资料页。
    if (content.find("<appmsg") != std::string::npos) {
        if (!canLink) return body;
        return EnsureSessionPrefix(BuildProfileSysmsg(body, token, event.members), event.groupID);
    }

    if (content.find('<') == std::string::npos) {
        if (!canLink) return body;
        return EnsureSessionPrefix(BuildProfileSysmsg(body, token, event.members), event.groupID);
    }

    std::string xml = content;
    ApplyPreferredNicknames(&xml);
    bool replaced = ReplaceMatchingTag(&xml, "template", body);
    replaced = ReplaceMatchingTag(&xml, "text", body) || replaced;
    if (!replaced) {
        if (!canLink) return body;
        return EnsureSessionPrefix(BuildProfileSysmsg(body, token, event.members), event.groupID);
    }
    if (canLink) InjectProfileLink(&xml, token, event.members);
    if (xml.find(kLeaveSentinel) == std::string::npos) xml += kLeaveSentinel;
    return EnsureSessionPrefix(xml, event.groupID);
}

struct LeaveSlot {
    void *address;
    std::string text;
};

void CollectLeaveSlots(const uint8_t *base, uint32_t messageType, std::vector<LeaveSlot> *out) {
    if (gContentOffset != 0) {
        std::string content;
        void *slot = const_cast<uint8_t *>(base + gContentOffset);
        if (ReadLibcppStringAt(slot, content)) out->push_back({slot, std::move(content)});
    }
    // type 49 的 +0x18 是 appmsg 模板串，不是群 ID/正文副本；改写它会把会话归属弄坏。
    if (messageType == kAppMessageType) return;
    void *fromSlot = const_cast<uint8_t *>(base + kCalibratedFromOffset);
    if (gContentOffset == kCalibratedFromOffset) return;
    std::string from;
    if (ReadLibcppStringAt(fromSlot, from) && !from.empty() && from[0] == '<') {
        out->push_back({fromSlot, std::move(from)});
    }
}

void AssignLeaveText(void *slot, const std::string &value) {
    if (!slot || value.empty()) return;
    if (!IsAddressRangeReadable(slot, sizeof(std::string))) return;
    auto *text = reinterpret_cast<std::string *>(slot);
    if (text->find(kLeaveSentinel) != std::string::npos) return;
    text->assign(value);
}

bool AssignFromUser(void *message, const std::string &groupID) {
    if (!message || groupID.empty()) return false;
    auto *base = reinterpret_cast<uint8_t *>(message);
    void *slot = base + kCalibratedFromOffset;
    std::string current;
    if (!ReadLibcppStringAt(slot, current)) return false;
    reinterpret_cast<std::string *>(slot)->assign(groupID);
    return true;
}

bool AssignMessageType(void *message, uint32_t type) {
    if (!message || gTypeOffset == 0) return false;
    auto *base = reinterpret_cast<uint8_t *>(message);
    if (!IsAddressRangeReadable(base + gTypeOffset, sizeof(type))) return false;
    memcpy(base + gTypeOffset, &type, sizeof(type));
    return true;
}

}  // namespace

// 捕获点观察者回调：每条进入收口函数的消息都会经过这里。先认 10000/10002/49，
// 再认退群文案。灰字每次都改，除非正文里已经有哨兵。
// 任何异常都必须吞掉——绝不能让解析器带病运行。
extern "C" void WCRGroupLeaveOnMessage(const void *message) {
    if (!message || !gEnabled.load()) return;

    const auto *base = reinterpret_cast<const uint8_t *>(message);
    uint32_t messageType = 0;
    if (!IsAddressRangeReadable(base + gTypeOffset, sizeof(messageType))) return;
    memcpy(&messageType, base + gTypeOffset, sizeof(messageType));
    if (messageType != kSystemTipType && messageType != kSystemCommandType &&
        messageType != kAppMessageType) return;

    @autoreleasepool {
        try {
            std::vector<LeaveSlot> slots;
            CollectLeaveSlots(base, messageType, &slots);

            std::vector<Member> borrowed;
            bool borrowedFromTable = false;
            GroupLeaveEvent noticeEvent;
            bool haveNotice = false;
            int noticeRank = -1;
            bool convertedAppMessage = false;
            std::string convertedGroupID;
            bool anyRewritten = false;
            for (const auto &slot : slots) {
                if (AlreadyRewritten(slot.text) || !LooksLikeGroupLeave(slot.text)) continue;
                GroupLeaveEvent event;
                if (!ParseGroupLeaveEvent(slot.text, const_cast<void *>(message), &event)) continue;
                bool memberTable = slot.text.find("<member>") != std::string::npos;
                int rank = memberTable ? 4 : 0;
                std::vector<Member> linkable;
                for (const auto &member : event.members) {
                    if (!MemberLinkable(member)) continue;
                    rank += 1;
                    linkable.push_back(member);
                }
                // 成员表里的群名片优先于明文里的微信昵称。
                if (!haveNotice || rank > noticeRank) {
                    noticeEvent = event;
                    noticeRank = rank;
                    haveNotice = true;
                }
                if (memberTable && !linkable.empty()) {
                    borrowed = linkable;
                    borrowedFromTable = true;
                } else if (borrowed.empty()) {
                    borrowed = linkable;
                }
            }

            for (const auto &slot : slots) {
                if (AlreadyRewritten(slot.text) || !LooksLikeGroupLeave(slot.text)) continue;
                GroupLeaveEvent event;
                if (!ParseGroupLeaveEvent(slot.text, const_cast<void *>(message), &event)) continue;
                bool slotCanLink = false;
                for (const auto &member : event.members) {
                    if (MemberLinkable(member)) slotCanLink = true;
                }
                if (borrowedFromTable || (!slotCanLink && !borrowed.empty())) {
                    event.members = borrowed;
                }
                std::string rewritten = RenderedPayload(slot.text, event);
                if (rewritten != slot.text) {
                    AssignLeaveText(slot.address, rewritten);
                    anyRewritten = true;
                    if (messageType == kAppMessageType) {
                        convertedAppMessage = true;
                        if (convertedGroupID.empty()) convertedGroupID = event.groupID;
                    }
                }
            }

            if (convertedAppMessage) {
                AssignMessageType(const_cast<void *>(message), kSystemTipType);
                AssignFromUser(const_cast<void *>(message), convertedGroupID);
                os_log_info(WCRLeaveLog(), "group leave appmsg converted to system tip");
            }

            if (anyRewritten && haveNotice) {
                std::string notice = RenderLeaveTemplate(noticeEvent.who, noticeEvent.timeText,
                                                         noticeEvent.whoID, noticeEvent.groupID,
                                                         false);
                if (!notice.empty()) {
                    WCRRecallNotifySendLeaveText(OwnedUTF8(notice), OwnedUTF8(noticeEvent.groupID));
                }
            }
        } catch (...) {
            // 退群事件解析失败不能影响微信消息管线。
        }
    }
}

BOOL WCRGroupLeaveMonitorSupportsProfile(const WCRPatchProfile *profile) {
    return profile && profile->messageFinalizerAddress != 0 &&
           profile->messageFinalizerContinuation != 0 &&
           profile->messageTypeOffset != 0 && profile->messageContentOffset != 0;
}

BOOL WCRGroupLeaveMonitorInstall(const WCRPatchProfile *profile, NSError **error) {
    if (gEnabled.load()) return YES;
    if (!WCRGroupLeaveMonitorSupportsProfile(profile)) {
        if (error) {
            *error = WCRLeaveError(@"当前微信构建尚未登记消息收口函数信息，退群监控不可用");
        }
        return NO;
    }

    gTypeOffset = profile->messageTypeOffset;
    gContentOffset = profile->messageContentOffset;
    gCreateTimeSecOffset = profile->messageCreateTimeSecOffset;
    // 观察者槽位由 WCRefineMac.mm 的统一分发器持有（WCRMessageCaptureDispatch
    // 转发给本函数），这里只开自己的开关。
    gEnabled.store(true);
    return YES;
}

BOOL WCRGroupLeaveMonitorUninstall(NSError **error) {
    (void)error;
    gEnabled.store(false);
    return YES;
}

BOOL WCRGroupLeaveMonitorIsInstalled(void) {
    return gEnabled.load();
}

NSString *WCRGroupLeaveDefaultTemplate(void) {
    return @"检测有人逃离此群！\n逃犯编号：{name}\n逃离时间：{time}";
}

NSString *WCRGroupLeaveStoredTemplate(void) {
    @autoreleasepool {
        NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:kTemplateDefaultsKey];
        NSString *trimmed = [stored stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        if (trimmed.length == 0 || trimmed.length > kMaxTemplateBytes) {
            return WCRGroupLeaveDefaultTemplate();
        }
        return trimmed;
    }
}

void WCRGroupLeaveSetStoredTemplate(NSString *templateString) {
    @autoreleasepool {
        NSString *trimmed = [templateString stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        if (trimmed.length == 0 || trimmed.length > kMaxTemplateBytes) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:kTemplateDefaultsKey];
            return;
        }
        [[NSUserDefaults standardUserDefaults] setObject:trimmed forKey:kTemplateDefaultsKey];
    }
}
