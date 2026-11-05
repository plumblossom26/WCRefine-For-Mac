#import "WCRCommentRepeat.h"

#import "WCRCodePatch.h"

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <libkern/OSCacheControl.h>

#import <atomic>
#import <cstdint>
#import <cstring>
#import <sys/mman.h>

#include <cstdio>
#include <ctime>

// 270351 朋友圈评论长按菜单。菜单对象是构建函数的返回值，所以先跑原函数，
// 再把「复读」插到动作列表最前面。点击时用评论行上的正文，再加上这条评论
// 自带的表情图片，走微信自己的评论发送入口。回复目标留空。不走聊天转发，
// 也不打开回复框。

extern "C" {

void *gWCRCommentRepeatTrampoline = nullptr;
void *gWCRCommentRepeatStringFromQ = nullptr;
void *gWCRCommentRepeatTextQ = nullptr;
void *gWCRCommentRepeatShareCopy = nullptr;
void *gWCRCommentRepeatConnectFn = nullptr;

void WCRCommentRepeatBuilderHook(void *collect, void *menu);
void WCRCommentRepeatSlot(int op, void *slot);
void WCRCommentRepeatStringFromQ(void *dest, void *qstring);
void WCRCommentRepeatTextQ(void *dest, void *textObject);
void WCRCommentRepeatWidgetText(void *dest, void *widget);
void WCRCommentRepeatShareCopy(void *dest, void *controller);
void WCRCommentRepeatConnect(void *action, void *methodPair, void *menu,
                             void *slot, void *qmeta, void *connection);

}  // extern "C"

namespace {

constexpr uint64_t kBuilderOffset = 0x1bfd67c;
constexpr uint64_t kAddItemOffset = 0x1f99618;
constexpr uint64_t kInsertActionOffset = 0x6b67ee4;
constexpr uint64_t kConnectOffset = 0x71489b0;
constexpr uint64_t kConnectCleanupOffset = 0x7144ac4;
constexpr uint64_t kMakeTitleOffset = 0x7065338;
constexpr uint64_t kMallocOffset = 0x72acd48;
constexpr uint64_t kFreeOffset = 0x72acd24;
constexpr uint64_t kQStringFreeOffset = 0x700e7dc;
constexpr uint64_t kStringFromQOffset = 0x20d820;
constexpr uint64_t kStringCopyOffset = 0x16d20;
constexpr uint64_t kStringCopyCtorOffset = 0x29318;
constexpr uint64_t kStringDestroyOffset = 0x2948c;
constexpr uint64_t kRecordAssignOffset = 0x1a1ebd4;
constexpr uint64_t kEmojiTypeGetterOffset = 0x47956f8;
constexpr uint64_t kTextQStringOffset = 0x1bfbc58;
constexpr uint64_t kTextGetterOffset = 0x20ac498;
constexpr uint64_t kInfoDestroyOffset = 0x1ed978;
constexpr uint64_t kShareCopyOffset = 0xf0f1f4;
constexpr uint64_t kShareReleaseOffset = 0x12968c;
constexpr uint64_t kDynCastOffset = 0x72ace44;
constexpr uint64_t kSubmitOffset = 0x1b5b250;
constexpr uint64_t kDescriptorSlotOffset = 0x9ea4670;
constexpr uint64_t kActionQMetaOffset = 0xa1012c8;
constexpr uint64_t kTriggeredOffset = 0x6b38030;
constexpr uint64_t kTypeInfoAOffset = 0x9e822f8;
constexpr uint64_t kTypeInfoBOffset = 0x9e82378;
constexpr uint64_t kViewVptrOffset = 0x9d24bf8;

constexpr uint32_t kBuilderPrologue[4] = {0x6db923e9, 0xa9016ffc, 0xa90267fa, 0xa9035ff8};
constexpr uint32_t kAddItemPrologue[4] = {0xd10183ff, 0xa90167fa, 0xa9025ff8, 0xa90357f6};
constexpr uint32_t kInsertActionPrologue[4] = {0xd10203ff, 0xa90367fa, 0xa9045ff8, 0xa90557f6};
constexpr uint32_t kConnectPrologue[4] = {0xd10283ff, 0xa90567fa, 0xa9065ff8, 0xa90757f6};
constexpr uint32_t kConnectCleanupPrologue[4] = {0xa9be4ff4, 0xa9017bfd, 0x910043fd, 0xaa0003f3};
constexpr uint32_t kMakeTitlePrologue[4] = {0xd100c3ff, 0xa9014ff4, 0xa9027bfd, 0x910083fd};
constexpr uint32_t kMallocPrologue[4] = {0xd0014e70, 0xf945a210, 0xd61f0200, 0xd0014e70};
constexpr uint32_t kFreePrologue[4] = {0xd0014e70, 0xf9459610, 0xd61f0200, 0xd0014e70};
constexpr uint32_t kQStringFreePrologue[4] = {0xb0019b88, 0x9124e108, 0xeb08001f, 0x54000040};
constexpr uint32_t kStringFromQPrologue[4] = {0xd10143ff, 0xa9015ff8, 0xa90257f6, 0xa9034ff4};
constexpr uint32_t kStringCopyPrologue[4] = {0xa9bd57f6, 0xa9014ff4, 0xa9027bfd, 0x910083fd};
constexpr uint32_t kStringCopyCtorPrologue[4] = {0x39c05c28, 0x37f800c8, 0x3dc00020, 0xf9400828};
constexpr uint32_t kStringDestroyPrologue[4] = {0x39c05c08, 0x37f80048, 0xd65f03c0, 0xa9be4ff4};
constexpr uint32_t kRecordAssignPrologue[4] = {0xa9bb67fa, 0xa9015ff8, 0xa90257f6, 0xa9034ff4};
constexpr uint32_t kEmojiTypeGetterPrologue[4] = {0x9002f108, 0xf944b500, 0xd65f03c0, 0xd100c3ff};
constexpr uint32_t kTextQStringPrologue[4] = {0xd10103ff, 0xa9024ff4, 0xa9037bfd, 0x9100c3fd};
constexpr uint32_t kTextGetterPrologue[4] = {0xf941cc09, 0xf9400120, 0xf9400009, 0xf940d921};
constexpr uint32_t kInfoDestroyPrologue[4] = {0xa9bc5ff8, 0xa90157f6, 0xa9024ff4, 0xa9037bfd};
constexpr uint32_t kShareCopyPrologue[4] = {0xa941240a, 0xa900250a, 0xb4000089, 0x91002128};
constexpr uint32_t kShareReleasePrologue[4] = {0xa9be4ff4, 0xa9017bfd, 0x910043fd, 0xf9400413};
constexpr uint32_t kDynCastPrologue[4] = {0xd0014e70, 0xf9460210, 0xd61f0200, 0xd0014e70};
constexpr uint32_t kSubmitPrologue[4] = {0xd10583ff, 0xa9125ff8, 0xa91357f6, 0xa9144ff4};

// 评论列表虚表有 kViewVptrOffset 和 kViewVptrAltOffset 两个兄弟类型。行和列表
// 之间还有内容容器，要沿父链向上找。评论行有 A/B 两套布局，字段偏移见下方
// kLayoutA/kLayoutB。B 型的 +0x220 是辅助对象，它的取字结果在点击时是空的，
// 只在布局识别失败时再试。QWidget 动作数组在 d_ptr+0x190。
constexpr size_t kObjectDPtrOffset = 8;
constexpr size_t kParentOffset = 0x10;
constexpr size_t kActionsOffset = 0x190;
constexpr size_t kControllerOffset = 0x240;
constexpr size_t kVisibleTextOffset = 0x1e8;
constexpr size_t kTextObjectOffset = 0x220;
constexpr uint64_t kTextVptrOffset = 0x9d1f940;
constexpr size_t kTextVectorOffset = 0x398;
constexpr size_t kTextVectorEndOffset = 0x3a0;
constexpr size_t kTextGetterSlot = 0x1f8;
constexpr size_t kTextRunMethod = 0x1b0;
constexpr size_t kCommentModelOffset = 0x9f8;
constexpr size_t kEmojiPointerOffset = 0xd8;
constexpr uint64_t kEmojiVptrOffset = 0x9e8a360;
constexpr size_t kEmojiStringOffset = 0x10;
constexpr size_t kEmojiString2Offset = 0x28;
constexpr size_t kInfoTextBytes = 0x18;
constexpr size_t kInfoRecordOffset = 0x18;
constexpr size_t kRecordBytes = 0x38;
constexpr size_t kRecordTypeOffset = 0x30;
constexpr size_t kEmojiTypeSlot = 0x50;
constexpr size_t kModelTextOffset = 0x40;
constexpr uint64_t kWeChatImageSize = 0xa672010;
constexpr size_t kInfoBytes = 0x48;
constexpr size_t kSlotBytes = 0x18;
constexpr size_t kTrampolineBytes = 32;
constexpr int kMaxParentWalk = 16;
constexpr int kMaxMenuActions = 64;
constexpr uint64_t kViewVptrAltOffset = 0x9d205f0;
constexpr uint64_t kEmojiVptrAltOffset = 0x9ff8428;

// 评论右键入口有两个行类型。A 型行较小，文字控件在 +0x1f0、评论模型在
// +0x230；B 型行是当前主列表常见布局，文字控件在 +0x1e8、评论模型在
// +0x1f0。两个原生菜单动作就是这么取正文的，不能只看其中一套。
constexpr size_t kLayoutAWidgetOffset = 0x1f0;
constexpr size_t kLayoutAModelOffset = 0x230;
constexpr size_t kLayoutBWidgetOffset = 0x1e8;
constexpr size_t kLayoutBModelOffset = 0x1f0;

struct CommentSites {
    const char *build;
    uint64_t builder;
};

struct CommentRowLayout {
    size_t widgetOffset;
    size_t modelOffset;
};

static const CommentSites kCommentSites[] = {
    {"270351", kBuilderOffset},
};

static const CommentSites *gSites = nullptr;
static std::atomic_bool gInstalled(false);
static std::atomic_bool gEnabled(false);
static std::atomic_bool gInFlight(false);
static std::atomic<uintptr_t> gSlide(0);
static thread_local bool gInBuilderHook = false;

static uint8_t *gBuilderEntry = nullptr;
static uint8_t gSavedPrologue[16];
static void *gMalloc = nullptr;
static void *gFree = nullptr;
static void *gQStringFree = nullptr;
static void *gAddItem = nullptr;
static void *gInsertAction = nullptr;
static void *gMakeTitle = nullptr;
static void *gConnectCleanup = nullptr;
static void *gInfoDestroy = nullptr;
static void *gStringCopy = nullptr;
static void *gStringCopyCtor = nullptr;
static void *gStringDestroy = nullptr;
static void *gRecordAssign = nullptr;
static void *gShareRelease = nullptr;
static void *gDynCast = nullptr;
static void *gSubmit = nullptr;
static FILE *gLog = nullptr;

using MallocFn = void *(*)(size_t size);
using FreeFn = void (*)(void *pointer, size_t size);
using QStringFreeFn = void (*)(void *data, int type, int align);
using MakeTitleFn = void *(*)(const char *text, int length);
using AddItemFn = void *(*)(void *menu, void *title, void *descriptor);
using InsertActionFn = void (*)(void *menu, void *before, void *action);
using CleanupFn = void (*)(void *connection);
using InfoDestroyFn = void (*)(void *info);
using StringCopyFn = void (*)(void *dest, const void *bytes, size_t size);
using StringCopyCtorFn = void (*)(void *dest, const void *source);
using StringDestroyFn = void (*)(void *text);
using RecordAssignFn = void (*)(void *vector, void *begin, void *end, uint64_t count);
using EmojiTypeSingletonFn = void *(*)();
using EmojiTypeFn = uint32_t (*)(void *service);
using ShareReleaseFn = void (*)(void *shared);
using DynCastFn = void *(*)(void *object, void *from, void *to, int zero);
using SubmitFn = void (*)(void *service, void *moment, void *reply, void *info);

static const CommentSites *CommentSitesFor(const char *build) {
    if (!build) return nullptr;
    for (const CommentSites &sites : kCommentSites) {
        if (strcmp(sites.build, build) == 0) return &sites;
    }
    return nullptr;
}

static NSError *CommentError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMac.CommentRepeat"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"朋友圈评论复读错误"}];
}

static FILE *CommentLog(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = [@"~/Library/Logs/WCRefine" stringByExpandingTildeInPath];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *path = [dir stringByAppendingPathComponent:@"comment-repeat.log"];
        gLog = fopen(path.fileSystemRepresentation, "a");
        if (gLog) {
            const char *build = [[[NSBundle mainBundle]
                objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String];
            fprintf(gLog, "=== comment repeat session %ld build=%s ===\n",
                    (long)time(nullptr), build ? build : "?");
            fflush(gLog);
        }
    });
    return gLog;
}

static void LogLine(NSString *line) {
    if (FILE *log = CommentLog()) {
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
                        NSString *name, NSError **error) {
    uint8_t actual[16] = {};
    if (!SafeRead(reinterpret_cast<const void *>(slide + offset), actual, sizeof(actual))) {
        if (error) *error = CommentError([NSString stringWithFormat:@"无法读取%@", name]);
        return false;
    }
    uint8_t wanted[16] = {};
    for (int index = 0; index < 4; ++index) {
        memcpy(wanted + index * 4, &expected[index], 4);
    }
    if (memcmp(actual, wanted, sizeof(actual)) != 0) {
        NSMutableString *hex = [NSMutableString string];
        for (uint8_t byte : actual) [hex appendFormat:@"%02x", byte];
        LogLine([NSString stringWithFormat:@"install: %@ prologue %@", name, hex]);
        if (error) {
            *error = CommentError([NSString stringWithFormat:@"%@字节不匹配（当前 %@）", name, hex]);
        }
        return false;
    }
    return true;
}

static bool ReadU64(const void *address, uint64_t *out) {
    return SafeRead(address, out, sizeof(*out));
}

static void ReleaseTitle(void *data) {
    if (!data || !gQStringFree) return;
    auto *ref = reinterpret_cast<std::atomic<int32_t> *>(data);
    int32_t current = ref->load(std::memory_order_acquire);
    if (current == -1) return;
    if (current != 0) {
        int32_t previous = ref->fetch_add(-1, std::memory_order_acq_rel);
        if (previous != 1) return;
    }
    reinterpret_cast<QStringFreeFn>(gQStringFree)(data, 2, 8);
}

static bool ReadI32(const void *address, int32_t *out) {
    return SafeRead(address, out, sizeof(*out));
}

static bool ObjectParent(uintptr_t object, uintptr_t *parent) {
    uint64_t dptr = 0;
    uint64_t value = 0;
    if (!ReadU64(reinterpret_cast<void *>(object + kObjectDPtrOffset), &dptr) ||
        !PlausiblePointer(dptr) ||
        !ReadU64(reinterpret_cast<void *>(dptr + kParentOffset), &value) ||
        !PlausiblePointer(value) || (value & 7) != 0) {
        return false;
    }
    *parent = static_cast<uintptr_t>(value);
    return true;
}

// 评论行的直接父级是内容容器，不是 0x2c8 的评论列表。沿父链找到列表虚表。
static bool FindCommentList(void *collect, uintptr_t slide, uintptr_t *view) {
    uintptr_t current = reinterpret_cast<uintptr_t>(collect);
    uint64_t seen[kMaxParentWalk] = {};
    int count = 0;
    for (int depth = 0; depth < kMaxParentWalk; ++depth) {
        uintptr_t parent = 0;
        if (!ObjectParent(current, &parent) || parent == current) break;
        uint64_t vptr = 0;
        if (!ReadU64(reinterpret_cast<void *>(parent), &vptr)) break;
        if (count < kMaxParentWalk) seen[count++] = vptr;
        if (vptr == slide + kViewVptrOffset || vptr == slide + kViewVptrAltOffset) {
            uint64_t raw = 0;
            if (ReadU64(reinterpret_cast<void *>(parent + kControllerOffset), &raw) &&
                PlausiblePointer(raw)) {
                *view = parent;
                return true;
            }
        }
        current = parent;
    }
    NSMutableString *line = [NSMutableString stringWithString:@"submit: comment list not found"];
    for (int index = 0; index < count; ++index) {
        const uint64_t relative = seen[index] > slide ? seen[index] - slide : seen[index];
        [line appendFormat:@" 0x%llx", (unsigned long long)relative];
    }
    LogLine(line);
    return false;
}

static bool StringEmpty(const uint8_t *text) {
    uint8_t flag = text[0x17];
    if (flag & 0x80) {
        uint64_t size = 0;
        memcpy(&size, text + 8, sizeof(size));
        return size == 0;
    }
    return flag == 0;
}

static bool StringBytes(const uint8_t *text, const uint8_t **bytes, size_t *size) {
    if (!text || !bytes || !size) return false;
    const uint8_t flag = text[0x17];
    if (flag & 0x80) {
        uint64_t pointer = 0;
        uint64_t length = 0;
        memcpy(&pointer, text, sizeof(pointer));
        memcpy(&length, text + 8, sizeof(length));
        if (!PlausiblePointer(pointer) || length == 0 || length > (1u << 20)) return false;
        *bytes = reinterpret_cast<const uint8_t *>(pointer);
        *size = static_cast<size_t>(length);
        return true;
    }
    if (flag == 0) return false;
    *bytes = text;
    *size = flag;
    return true;
}

static bool StringLayoutLooksValid(const uint8_t *text) {
    alignas(16) uint8_t copy[24] = {};
    if (!text || !SafeRead(text, copy, sizeof(copy))) return false;
    const uint8_t flag = copy[0x17];
    if (flag & 0x80) {
        uint64_t pointer = 0;
        uint64_t length = 0;
        memcpy(&pointer, copy, sizeof(pointer));
        memcpy(&length, copy + 8, sizeof(length));
        return PlausiblePointer(pointer) && length <= (1u << 20);
    }
    return flag <= 22;
}

static void ReleaseLongString(uint8_t *text) {
    if (!text) return;
    if ((text[0x17] & 0x80) && gFree) {
        uint64_t pointer = 0;
        uint64_t capacity = 0;
        memcpy(&pointer, text, sizeof(pointer));
        memcpy(&capacity, text + 16, sizeof(capacity));
        capacity &= 0x7fffffffffffffffULL;
        if (pointer != 0) {
            reinterpret_cast<FreeFn>(gFree)(reinterpret_cast<void *>(pointer), capacity);
        }
    }
    memset(text, 0, 24);
}

static bool TextWidgetAt(void *collect, uintptr_t slide, size_t offset, uint64_t *widget) {
    uint64_t candidate = 0;
    uint64_t vptr = 0;
    if (!ReadU64(static_cast<uint8_t *>(collect) + offset, &candidate) ||
        !PlausiblePointer(candidate) || !ReadU64(reinterpret_cast<void *>(candidate), &vptr) ||
        vptr != slide + kTextVptrOffset) {
        return false;
    }
    *widget = candidate;
    return true;
}

static bool CommentRowLayoutFor(void *collect, uintptr_t slide, CommentRowLayout *layout) {
    if (!collect || !slide || !layout) return false;
    uint64_t widget = 0;
    if (TextWidgetAt(collect, slide, kLayoutAWidgetOffset, &widget)) {
        layout->widgetOffset = kLayoutAWidgetOffset;
        layout->modelOffset = kLayoutAModelOffset;
        return true;
    }
    if (TextWidgetAt(collect, slide, kLayoutBWidgetOffset, &widget)) {
        layout->widgetOffset = kLayoutBWidgetOffset;
        layout->modelOffset = kLayoutBModelOffset;
        return true;
    }
    return false;
}

// 原生右键动作直接从评论模型的 +0x40 取正文；这比从可见文字里剥昵称更稳，
// 也不会因为两套行布局的文字控件偏移不同而取空。
static bool CopyModelComment(void *collect, const CommentRowLayout &layout, uint8_t *info) {
    if (!gStringCopy) return false;
    uint64_t model = 0;
    if (!ReadU64(static_cast<uint8_t *>(collect) + layout.modelOffset, &model) ||
        !PlausiblePointer(model)) {
        LogLine(@"submit: comment model missing");
        return false;
    }
    const uint8_t *bytes = nullptr;
    size_t size = 0;
    if (!StringBytes(reinterpret_cast<const uint8_t *>(model) + kModelTextOffset, &bytes, &size)) {
        LogLine(@"submit: comment model text empty");
        return false;
    }
    reinterpret_cast<StringCopyFn>(gStringCopy)(info, bytes, size);
    return true;
}

// 可见文字控件的虚表 +0x1f8 会把整行写成 std::string，里面含昵称。
// 调用前核对虚表、取字函数和文字片段，对不上就放弃。
static bool CopyVisibleComment(void *collect, uintptr_t slide, size_t widgetOffset, uint8_t *info) {
    uint64_t widget = 0;
    if (!ReadU64(static_cast<uint8_t *>(collect) + widgetOffset, &widget) ||
        !PlausiblePointer(widget)) {
        LogLine(@"submit: visible text missing");
        return false;
    }
    uint64_t vptr = 0;
    if (!ReadU64(reinterpret_cast<void *>(widget), &vptr) || vptr != slide + kTextVptrOffset) {
        LogLine(@"submit: visible text type mismatch");
        return false;
    }
    if (!VerifyEntry(slide, kTextGetterOffset, kTextGetterPrologue, @"可见评论文字", nullptr)) {
        LogLine(@"submit: visible text getter changed");
        return false;
    }
    uint64_t method = 0;
    if (!ReadU64(reinterpret_cast<void *>(vptr + kTextGetterSlot), &method) ||
        method != slide + kTextGetterOffset) {
        LogLine(@"submit: visible text getter mismatch");
        return false;
    }
    uint64_t begin = 0;
    uint64_t end = 0;
    if (!ReadU64(reinterpret_cast<void *>(widget + kTextVectorOffset), &begin) ||
        !ReadU64(reinterpret_cast<void *>(widget + kTextVectorEndOffset), &end) ||
        !PlausiblePointer(begin) || end <= begin) {
        LogLine(@"submit: visible text runs empty");
        return false;
    }
    uint64_t run = 0;
    if (!ReadU64(reinterpret_cast<void *>(begin), &run) || !PlausiblePointer(run)) {
        LogLine(@"submit: visible text run missing");
        return false;
    }
    uint64_t runVptr = 0;
    if (!ReadU64(reinterpret_cast<void *>(run), &runVptr) || !PlausiblePointer(runVptr)) {
        LogLine(@"submit: visible text run type missing");
        return false;
    }
    uint64_t inner = 0;
    if (!ReadU64(reinterpret_cast<void *>(runVptr + kTextRunMethod), &inner) ||
        !PlausiblePointer(inner)) {
        LogLine(@"submit: visible text run method missing");
        return false;
    }
    WCRCommentRepeatWidgetText(info, reinterpret_cast<void *>(widget));
    return true;
}

// 评论行显示成「昵称：正文」。全角冒号前面是名字，复读只发送后面的正文。
// 冒号后多出来的一个空格是展示分隔，不属于评论。
static void StripDisplayedName(uint8_t *text) {
    if (!text || !gStringCopy) return;
    const uint8_t *bytes = nullptr;
    size_t size = 0;
    const uint8_t flag = text[0x17];
    if (flag & 0x80) {
        uint64_t pointer = 0;
        memcpy(&pointer, text, sizeof(pointer));
        memcpy(&size, text + 8, sizeof(size));
        if (!PlausiblePointer(pointer)) return;
        bytes = reinterpret_cast<const uint8_t *>(pointer);
    } else {
        bytes = text;
        size = flag;
    }
    if (!bytes || size < 3) return;
    static const uint8_t kNameSeparator[] = {0xef, 0xbc, 0x9a};
    size_t skip = 0;
    bool found = false;
    for (size_t index = 0; index + 3 <= size; ++index) {
        if (memcmp(bytes + index, kNameSeparator, 3) != 0) continue;
        skip = index + 3;
        found = true;
        break;
    }
    if (!found || skip > size) return;
    if (skip < size && bytes[skip] == ' ') skip += 1;
    alignas(16) uint8_t trimmed[24] = {};
    reinterpret_cast<StringCopyFn>(gStringCopy)(trimmed, bytes + skip, size - skip);
    ReleaseLongString(text);
    memcpy(text, trimmed, sizeof(trimmed));
}

static void DestroyRecord(uint8_t *record) {
    ReleaseLongString(record + kInfoTextBytes);
    if (gStringDestroy) {
        reinterpret_cast<StringDestroyFn>(gStringDestroy)(record);
    } else {
        ReleaseLongString(record);
    }
}

// 文字控件 +0x9f8 上的评论模型把表情图片放在 +0xd8。对象是 0x40 字节，
// 两段字符串在 +0x10 和 +0x28。270351 同一布局有两个表情虚表：普通表情
// 0x9e8a360 和带 emoticon 字段的变体 0x9ff8428。发送记录由两段字符串加上
// 作曲器同一条虚函数取出的类型码组成。第二段为空时微信自己也不会写入。
static bool AttachEmoji(void *collect, uintptr_t slide, size_t widgetOffset, uint8_t *info) {
    if (!gStringCopyCtor || !gStringDestroy || !gRecordAssign) return false;
    uint64_t widget = 0;
    if (!ReadU64(static_cast<uint8_t *>(collect) + widgetOffset, &widget) ||
        !PlausiblePointer(widget)) {
        return false;
    }
    uint64_t widgetVptr = 0;
    if (!ReadU64(reinterpret_cast<void *>(widget), &widgetVptr) ||
        widgetVptr != slide + kTextVptrOffset) {
        return false;
    }
    uint8_t *comment = reinterpret_cast<uint8_t *>(widget) + kCommentModelOffset;
    uint64_t emoji = 0;
    uint64_t control = 0;
    if (!ReadU64(comment + kEmojiPointerOffset, &emoji) ||
        !ReadU64(comment + kEmojiPointerOffset + 8, &control) ||
        emoji == 0 || control == 0 || !PlausiblePointer(emoji)) {
        return false;
    }
    uint64_t emojiVptr = 0;
    if (!ReadU64(reinterpret_cast<void *>(emoji), &emojiVptr) ||
        (emojiVptr != slide + kEmojiVptrOffset && emojiVptr != slide + kEmojiVptrAltOffset)) {
        unsigned long long seen = 0;
        if (emojiVptr >= slide) seen = emojiVptr - slide;
        LogLine([NSString stringWithFormat:@"submit: emoji type mismatch %llx", seen]);
        return false;
    }
    if (emojiVptr == slide + kEmojiVptrAltOffset) LogLine(@"submit: emoji alternate type");
    if (!StringLayoutLooksValid(reinterpret_cast<const uint8_t *>(emoji) + kEmojiStringOffset) ||
        !StringLayoutLooksValid(reinterpret_cast<const uint8_t *>(emoji) + kEmojiString2Offset)) {
        LogLine(@"submit: emoji string layout mismatch");
        return false;
    }
    if (!VerifyEntry(slide, kStringCopyCtorOffset, kStringCopyCtorPrologue, @"表情字符串复制", nullptr) ||
        !VerifyEntry(slide, kStringDestroyOffset, kStringDestroyPrologue, @"表情字符串释放", nullptr) ||
        !VerifyEntry(slide, kRecordAssignOffset, kRecordAssignPrologue, @"表情记录写入", nullptr) ||
        !VerifyEntry(slide, kEmojiTypeGetterOffset, kEmojiTypeGetterPrologue, @"表情类型", nullptr)) {
        LogLine(@"submit: emoji entry changed");
        return false;
    }

    void *service = reinterpret_cast<EmojiTypeSingletonFn>(slide + kEmojiTypeGetterOffset)();
    if (!PlausiblePointer(reinterpret_cast<uintptr_t>(service))) {
        LogLine(@"submit: emoji type missing");
        return false;
    }
    uint64_t serviceVptr = 0;
    uint64_t typeMethod = 0;
    if (!ReadU64(service, &serviceVptr) || !PlausiblePointer(serviceVptr) ||
        !ReadU64(reinterpret_cast<void *>(serviceVptr + kEmojiTypeSlot), &typeMethod) ||
        typeMethod < slide || typeMethod >= slide + kWeChatImageSize) {
        LogLine(@"submit: emoji type missing");
        return false;
    }
    uint32_t type = reinterpret_cast<EmojiTypeFn>(typeMethod)(service);

    alignas(16) uint8_t record[kRecordBytes] = {};
    bool copied = false;
    try {
        reinterpret_cast<StringCopyCtorFn>(gStringCopyCtor)(
            record, reinterpret_cast<void *>(emoji + kEmojiStringOffset));
        copied = true;
        reinterpret_cast<StringCopyCtorFn>(gStringCopyCtor)(
            record + kInfoTextBytes, reinterpret_cast<void *>(emoji + kEmojiString2Offset));
        memcpy(record + kRecordTypeOffset, &type, sizeof(type));
        if (StringEmpty(record + kInfoTextBytes)) {
            DestroyRecord(record);
            LogLine(@"submit: emoji record incomplete");
            return false;
        }
        reinterpret_cast<RecordAssignFn>(gRecordAssign)(
            info + kInfoRecordOffset, record, record + kRecordBytes, 1);
        DestroyRecord(record);
        copied = false;
    } catch (...) {
        if (copied) DestroyRecord(record);
        LogLine(@"submit: emoji copy threw");
        return false;
    }
    LogLine(@"submit: emoji attached");
    return true;
}

static void SubmitComment(void *collect) {
    const uintptr_t slide = gSlide.load(std::memory_order_acquire);
    if (!slide || !gSubmit || !gDynCast || !gInfoDestroy || !gShareRelease) {
        LogLine(@"submit: skipped missing send entry");
        return;
    }
    if (!VerifyEntry(slide, kSubmitOffset, kSubmitPrologue, @"评论发送入口", nullptr)) {
        LogLine(@"submit: native send entry changed; skipped");
        return;
    }

    uintptr_t view = 0;
    if (!FindCommentList(collect, slide, &view)) return;

    uint64_t raw = 0;
    if (!ReadU64(reinterpret_cast<void *>(view + kControllerOffset), &raw) ||
        !PlausiblePointer(raw)) {
        LogLine(@"submit: controller missing");
        return;
    }
    void *controller = reinterpret_cast<DynCastFn>(gDynCast)(
        reinterpret_cast<void *>(raw),
        reinterpret_cast<void *>(slide + kTypeInfoAOffset),
        reinterpret_cast<void *>(slide + kTypeInfoBOffset),
        0);
    if (!controller) {
        LogLine(@"submit: controller cast failed");
        return;
    }

    alignas(16) uint8_t moment[16] = {};
    WCRCommentRepeatShareCopy(moment, controller);
    uint64_t momentObject = 0;
    memcpy(&momentObject, moment, sizeof(momentObject));
    if (momentObject == 0) {
        reinterpret_cast<ShareReleaseFn>(gShareRelease)(moment);
        LogLine(@"submit: moment missing");
        return;
    }

    CommentRowLayout layout = {};
    const bool hasLayout = CommentRowLayoutFor(collect, slide, &layout);
    if (!hasLayout) LogLine(@"submit: comment row layout unknown");

    alignas(16) uint8_t info[kInfoBytes] = {};
    bool copiedText = false;
    if (hasLayout) {
        copiedText = CopyModelComment(collect, layout, info);
        if (!copiedText) {
            ReleaseLongString(info);
            copiedText = CopyVisibleComment(collect, slide, layout.widgetOffset, info) &&
                         !StringEmpty(info);
            if (copiedText) StripDisplayedName(info);
        }
    } else {
        copiedText = CopyVisibleComment(collect, slide, kVisibleTextOffset, info) &&
                     !StringEmpty(info);
        if (copiedText) StripDisplayedName(info);
    }
    if (!copiedText && !hasLayout) {
        ReleaseLongString(info);
        uint64_t textObject = 0;
        if (!ReadU64(static_cast<uint8_t *>(collect) + kTextObjectOffset, &textObject) ||
            !PlausiblePointer(textObject)) {
            LogLine(@"submit: comment text object missing");
        } else {
            alignas(16) uint8_t qstring[8] = {};
            WCRCommentRepeatTextQ(qstring, reinterpret_cast<void *>(textObject));
            uint64_t textData = 0;
            memcpy(&textData, qstring, sizeof(textData));
            if (!PlausiblePointer(textData)) {
                LogLine(@"submit: comment text missing");
            } else {
                WCRCommentRepeatStringFromQ(info, qstring);
                ReleaseTitle(reinterpret_cast<void *>(textData));
            }
        }
    }
    // 纯表情图片的可见文字只剩昵称。剥掉昵称后正文为空，表情记录还在就可以发送。
    bool emoji = AttachEmoji(collect, slide,
                             hasLayout ? layout.widgetOffset : kVisibleTextOffset, info);
    if (StringEmpty(info) && !emoji) {
        reinterpret_cast<InfoDestroyFn>(gInfoDestroy)(info);
        reinterpret_cast<ShareReleaseFn>(gShareRelease)(moment);
        LogLine(@"submit: empty comment");
        return;
    }

    // 两个 0 是空 shared_ptr。发送函数会读这块内存；传空指针会崩。
    // 空回复目标把文字发成这条朋友圈下的新评论。
    alignas(16) uint8_t reply[16] = {};
    bool submitted = false;
    try {
        reinterpret_cast<SubmitFn>(gSubmit)(reinterpret_cast<void *>(view), moment, reply, info);
        submitted = true;
    } catch (...) {
        LogLine(@"submit: native call threw");
    }
    reinterpret_cast<InfoDestroyFn>(gInfoDestroy)(info);
    reinterpret_cast<ShareReleaseFn>(gShareRelease)(moment);
    if (submitted) LogLine(@"submit: ok");
}

static void HandleSlot(int op, void *slot) {
    if (op == 1) {
        if (!gEnabled.load(std::memory_order_acquire) || !gInstalled.load() || !slot) return;
        if (![NSThread isMainThread]) {
            LogLine(@"invoke: ignored off-main-thread click");
            return;
        }
        if (gInFlight.exchange(true)) return;
        void *collect = nullptr;
        memcpy(&collect, static_cast<uint8_t *>(slot) + 0x10, sizeof(collect));
        if (!collect) {
            gInFlight.store(false);
            return;
        }
        @try {
            try {
                SubmitComment(collect);
            } catch (...) {
                LogLine(@"invoke: native call threw");
            }
        } @catch (NSException *) {
            LogLine(@"invoke: exception");
        }
        gInFlight.store(false);
        return;
    }
    if (op == 0 && slot && gFree) {
        reinterpret_cast<FreeFn>(gFree)(slot, kSlotBytes);
    }
}

// 0x1f99618 只追加。AI 解读在本钩子返回后才加入，所以这里把新动作移到下标 0。
static void MoveRepeatFirst(void *menu, void *action) {
    if (!gInsertAction || !menu || !action) return;
    uint64_t dptr = 0;
    uint64_t list = 0;
    if (!ReadU64(static_cast<uint8_t *>(menu) + kObjectDPtrOffset, &dptr) ||
        !PlausiblePointer(dptr) ||
        !ReadU64(reinterpret_cast<void *>(dptr + kActionsOffset), &list) ||
        !PlausiblePointer(list)) {
        LogLine(@"append: menu actions unreadable");
        return;
    }
    int32_t begin = 0;
    int32_t end = 0;
    if (!ReadI32(reinterpret_cast<void *>(list + 8), &begin) ||
        !ReadI32(reinterpret_cast<void *>(list + 12), &end) ||
        begin < 0 || end <= begin || end - begin > kMaxMenuActions) {
        LogLine(@"append: menu action count rejected");
        return;
    }
    uint64_t first = 0;
    const uintptr_t slot = list + 0x10 + static_cast<uintptr_t>(begin) * 8;
    if (!ReadU64(reinterpret_cast<void *>(slot), &first) || !PlausiblePointer(first)) {
        LogLine(@"append: first menu action unreadable");
        return;
    }
    if (reinterpret_cast<void *>(first) == action) return;
    reinterpret_cast<InsertActionFn>(gInsertAction)(menu, reinterpret_cast<void *>(first), action);
    LogLine(@"append: repeat item moved first");
}

static void AppendRepeatItem(void *collect, void *menu) {
    if (!collect || !menu || !gAddItem || !gMakeTitle || !gMalloc || !gFree) return;
    const uintptr_t slide = gSlide.load(std::memory_order_acquire);
    if (!slide) return;

    uint64_t descriptor = 0;
    if (!ReadU64(reinterpret_cast<void *>(slide + kDescriptorSlotOffset), &descriptor) ||
        !PlausiblePointer(descriptor)) {
        LogLine(@"append: menu descriptor missing");
        return;
    }

    static const char titleBytes[] = "复读";
    void *title = reinterpret_cast<MakeTitleFn>(gMakeTitle)(titleBytes, -1);
    if (!title) {
        LogLine(@"append: title factory returned null");
        return;
    }
    void *qstring = title;
    void *action = reinterpret_cast<AddItemFn>(gAddItem)(menu, &qstring, reinterpret_cast<void *>(descriptor));
    ReleaseTitle(qstring);
    if (!action) {
        LogLine(@"append: native item was rejected");
        return;
    }
    MoveRepeatFirst(menu, action);

    void *slot = reinterpret_cast<MallocFn>(gMalloc)(kSlotBytes);
    if (!slot) {
        LogLine(@"append: slot allocation failed");
        return;
    }
    memset(slot, 0, kSlotBytes);
    uint32_t flag = 1;
    void *function = reinterpret_cast<void *>(&WCRCommentRepeatSlot);
    memcpy(slot, &flag, sizeof(flag));
    memcpy(static_cast<uint8_t *>(slot) + 8, &function, sizeof(function));
    memcpy(static_cast<uint8_t *>(slot) + 0x10, &collect, sizeof(collect));

    uint64_t methodPair[2] = {slide + kTriggeredOffset, 0};
    alignas(16) uint8_t connection[16] = {};
    WCRCommentRepeatConnect(action, methodPair, menu, slot,
                            reinterpret_cast<void *>(slide + kActionQMetaOffset),
                            connection);
    if (gConnectCleanup) {
        reinterpret_cast<CleanupFn>(gConnectCleanup)(connection);
    }
    LogLine(@"append: repeat item added");
}

}  // namespace

extern "C" void WCRCommentRepeatSlot(int op, void *slot) {
    HandleSlot(op, slot);
}

extern "C" void WCRCommentRepeatBuilderHook(void *collect, void *menu) {
    if (!gEnabled.load(std::memory_order_acquire) || !collect || !menu) return;
    if (gInBuilderHook) return;
    gInBuilderHook = true;
    @try {
        try {
            AppendRepeatItem(collect, menu);
        } catch (...) {
            LogLine(@"append: native allocation failed");
        }
    } @catch (NSException *) {
        LogLine(@"append: exception");
    }
    gInBuilderHook = false;
}

/// x0 = 目标 std::string，x1 = 可见文字控件。虚表 +0x1f8 从 x8 取目标地址。
__attribute__((naked)) extern "C" void WCRCommentRepeatWidgetText(void *dest, void *widget) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-16]!\n"
        "mov x8, x0\n"
        "mov x0, x1\n"
        "ldr x9, [x0]\n"
        "ldr x9, [x9, #0x1f8]\n"
        "blr x9\n"
        "ldp x29, x30, [sp], #16\n"
        "ret\n");
}

/// x0 = 目标 QString，x1 = 行上的文本对象。0x1bfbc58 从 x8 取目标地址。
__attribute__((naked)) extern "C" void WCRCommentRepeatTextQ(void *dest, void *textObject) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-16]!\n"
        "mov x8, x0\n"
        "mov x0, x1\n"
        "adrp x16, _gWCRCommentRepeatTextQ@PAGE\n"
        "ldr x16, [x16, _gWCRCommentRepeatTextQ@PAGEOFF]\n"
        "blr x16\n"
        "ldp x29, x30, [sp], #16\n"
        "ret\n");
}

/// x0 = 目标 std::string，x1 = QString*。0x20d820 从 x8 取目标地址。
__attribute__((naked)) extern "C" void WCRCommentRepeatStringFromQ(void *dest, void *qstring) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-16]!\n"
        "mov x8, x0\n"
        "mov x0, x1\n"
        "adrp x16, _gWCRCommentRepeatStringFromQ@PAGE\n"
        "ldr x16, [x16, _gWCRCommentRepeatStringFromQ@PAGEOFF]\n"
        "blr x16\n"
        "ldp x29, x30, [sp], #16\n"
        "ret\n");
}

/// x0 = 目标 shared_ptr，x1 = controller。0xf0f1f4 从 x8 取目标，并复制 controller+0x10。
__attribute__((naked)) extern "C" void WCRCommentRepeatShareCopy(void *dest, void *controller) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-16]!\n"
        "mov x8, x0\n"
        "mov x0, x1\n"
        "adrp x16, _gWCRCommentRepeatShareCopy@PAGE\n"
        "ldr x16, [x16, _gWCRCommentRepeatShareCopy@PAGEOFF]\n"
        "blr x16\n"
        "ldp x29, x30, [sp], #16\n"
        "ret\n");
}

/// x8 是连接临时对象。调用后要用 0x7144ac4 把它释放掉，连接本身留在菜单项上。
__attribute__((naked)) extern "C" void WCRCommentRepeatConnect(
    void *action, void *methodPair, void *menu, void *slot, void *qmeta, void *connection) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-16]!\n"
        "mov x8, x5\n"
        "mov x7, x4\n"
        "mov x4, x3\n"
        "mov x3, xzr\n"
        "mov w5, wzr\n"
        "mov x6, xzr\n"
        "adrp x16, _gWCRCommentRepeatConnectFn@PAGE\n"
        "ldr x16, [x16, _gWCRCommentRepeatConnectFn@PAGEOFF]\n"
        "blr x16\n"
        "ldp x29, x30, [sp], #16\n"
        "ret\n");
}

/// 原函数把菜单放在 x0 里返回。先跑完原函数，再追加，然后把同一个菜单交回去。
__attribute__((naked)) extern "C" void WCRCommentRepeatBuilderStub(void) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-128]!\n"
        "stp x0, x1, [sp, #16]\n"
        "stp x2, x3, [sp, #32]\n"
        "stp x4, x5, [sp, #48]\n"
        "stp x6, x7, [sp, #64]\n"
        "str x8, [sp, #80]\n"
        "adrp x16, _gWCRCommentRepeatTrampoline@PAGE\n"
        "ldr x16, [x16, _gWCRCommentRepeatTrampoline@PAGEOFF]\n"
        "blr x16\n"
        "str x0, [sp, #96]\n"
        "ldr x0, [sp, #16]\n"
        "ldr x1, [sp, #96]\n"
        "bl _WCRCommentRepeatBuilderHook\n"
        "ldr x0, [sp, #96]\n"
        "ldp x29, x30, [sp], #128\n"
        "ret\n");
}

BOOL WCRCommentRepeatSupportsProfile(const WCRPatchProfile *profile) {
    return profile && profile->commentMenuBuilderAddress != 0 &&
           CommentSitesFor(profile->buildVersion) != nullptr;
}

BOOL WCRCommentRepeatInstall(const WCRPatchProfile *profile, NSError **error) {
    if (gInstalled.load()) return YES;
    if (!WCRCommentRepeatSupportsProfile(profile)) {
        if (error) *error = CommentError(@"当前微信构建没有朋友圈评论复读所需的入口");
        return NO;
    }
    gSites = CommentSitesFor(profile->buildVersion);
    if (memcmp(profile->commentMenuBuilderPrologue, kBuilderPrologue, sizeof(kBuilderPrologue)) != 0 ||
        profile->commentMenuBuilderAddress != gSites->builder) {
        if (error) *error = CommentError(@"朋友圈评论菜单入口与已核对序言不一致");
        return NO;
    }

    uintptr_t slide = CurrentWeChatSlide();
    if (!slide) {
        if (error) *error = CommentError(@"wechat.dylib 尚未加载");
        return NO;
    }

    auto *entry = reinterpret_cast<uint8_t *>(slide + profile->commentMenuBuilderAddress);
    uint8_t current[16] = {};
    if (!SafeRead(entry, current, sizeof(current))) {
        if (error) *error = CommentError(@"无法读取朋友圈评论菜单入口");
        return NO;
    }
    if (memcmp(current, profile->commentMenuBuilderPrologue, sizeof(current)) != 0) {
        NSMutableString *actual = [NSMutableString string];
        for (uint8_t byte : current) [actual appendFormat:@"%02x", byte];
        LogLine([NSString stringWithFormat:@"install: prologue mismatch %@", actual]);
        if (error) *error = CommentError([NSString stringWithFormat:
            @"朋友圈评论菜单入口字节不匹配（当前 %@）", actual]);
        return NO;
    }

    if (!VerifyEntry(slide, kAddItemOffset, kAddItemPrologue, @"评论菜单添加项", error) ||
        !VerifyEntry(slide, kInsertActionOffset, kInsertActionPrologue, @"评论菜单插入项", error) ||
        !VerifyEntry(slide, kConnectOffset, kConnectPrologue, @"评论菜单连接", error) ||
        !VerifyEntry(slide, kConnectCleanupOffset, kConnectCleanupPrologue, @"评论菜单连接释放", error) ||
        !VerifyEntry(slide, kMakeTitleOffset, kMakeTitlePrologue, @"评论菜单标题", error) ||
        !VerifyEntry(slide, kMallocOffset, kMallocPrologue, @"评论菜单分配", error) ||
        !VerifyEntry(slide, kFreeOffset, kFreePrologue, @"评论菜单释放", error) ||
        !VerifyEntry(slide, kQStringFreeOffset, kQStringFreePrologue, @"评论菜单标题释放", error) ||
        !VerifyEntry(slide, kStringFromQOffset, kStringFromQPrologue, @"评论文字转换", error) ||
        !VerifyEntry(slide, kStringCopyOffset, kStringCopyPrologue, @"评论文字复制", error) ||
        !VerifyEntry(slide, kStringCopyCtorOffset, kStringCopyCtorPrologue, @"表情字符串复制", error) ||
        !VerifyEntry(slide, kStringDestroyOffset, kStringDestroyPrologue, @"表情字符串释放", error) ||
        !VerifyEntry(slide, kRecordAssignOffset, kRecordAssignPrologue, @"表情记录写入", error) ||
        !VerifyEntry(slide, kEmojiTypeGetterOffset, kEmojiTypeGetterPrologue, @"表情类型", error) ||
        !VerifyEntry(slide, kTextQStringOffset, kTextQStringPrologue, @"评论文字读取", error) ||
        !VerifyEntry(slide, kTextGetterOffset, kTextGetterPrologue, @"可见评论文字", error) ||
        !VerifyEntry(slide, kInfoDestroyOffset, kInfoDestroyPrologue, @"评论内容释放", error) ||
        !VerifyEntry(slide, kShareCopyOffset, kShareCopyPrologue, @"评论动态复制", error) ||
        !VerifyEntry(slide, kShareReleaseOffset, kShareReleasePrologue, @"评论动态释放", error) ||
        !VerifyEntry(slide, kDynCastOffset, kDynCastPrologue, @"评论控制器转换", error) ||
        !VerifyEntry(slide, kSubmitOffset, kSubmitPrologue, @"评论发送入口", error)) {
        return NO;
    }

    void *trampoline = mmap(nullptr, kTrampolineBytes, PROT_READ | PROT_WRITE,
                            MAP_ANON | MAP_PRIVATE, -1, 0);
    if (trampoline == MAP_FAILED) {
        if (error) *error = CommentError(@"无法分配朋友圈评论复读跳板");
        return NO;
    }
    auto *bytes = static_cast<uint8_t *>(trampoline);
    memcpy(bytes, current, 16);
    uint32_t tail[2] = {0x58000050u, 0xD61F0200u};  // ldr x16, #8; br x16
    memcpy(bytes + 16, tail, sizeof(tail));
    uint64_t continueAddress = reinterpret_cast<uint64_t>(entry) + 16;
    memcpy(bytes + 24, &continueAddress, sizeof(continueAddress));
    sys_icache_invalidate(bytes, kTrampolineBytes);
    if (mprotect(trampoline, kTrampolineBytes, PROT_READ | PROT_EXEC) != 0) {
        munmap(trampoline, kTrampolineBytes);
        if (error) *error = CommentError(@"无法将朋友圈评论复读跳板设为可执行");
        return NO;
    }

    uint8_t patch[16] = {};
    memcpy(patch, tail, sizeof(tail));
    uint64_t hookAddress = reinterpret_cast<uint64_t>(&WCRCommentRepeatBuilderStub);
    memcpy(patch + 8, &hookAddress, sizeof(hookAddress));

    gSlide.store(slide);
    gMalloc = reinterpret_cast<void *>(slide + kMallocOffset);
    gFree = reinterpret_cast<void *>(slide + kFreeOffset);
    gQStringFree = reinterpret_cast<void *>(slide + kQStringFreeOffset);
    gAddItem = reinterpret_cast<void *>(slide + kAddItemOffset);
    gInsertAction = reinterpret_cast<void *>(slide + kInsertActionOffset);
    gMakeTitle = reinterpret_cast<void *>(slide + kMakeTitleOffset);
    gConnectCleanup = reinterpret_cast<void *>(slide + kConnectCleanupOffset);
    gInfoDestroy = reinterpret_cast<void *>(slide + kInfoDestroyOffset);
    gStringCopy = reinterpret_cast<void *>(slide + kStringCopyOffset);
    gStringCopyCtor = reinterpret_cast<void *>(slide + kStringCopyCtorOffset);
    gStringDestroy = reinterpret_cast<void *>(slide + kStringDestroyOffset);
    gRecordAssign = reinterpret_cast<void *>(slide + kRecordAssignOffset);
    gShareRelease = reinterpret_cast<void *>(slide + kShareReleaseOffset);
    gDynCast = reinterpret_cast<void *>(slide + kDynCastOffset);
    gSubmit = reinterpret_cast<void *>(slide + kSubmitOffset);
    gWCRCommentRepeatStringFromQ = reinterpret_cast<void *>(slide + kStringFromQOffset);
    gWCRCommentRepeatTextQ = reinterpret_cast<void *>(slide + kTextQStringOffset);
    gWCRCommentRepeatShareCopy = reinterpret_cast<void *>(slide + kShareCopyOffset);
    gWCRCommentRepeatConnectFn = reinterpret_cast<void *>(slide + kConnectOffset);
    gWCRCommentRepeatTrampoline = trampoline;

    NSError *patchError = nil;
    if (!WCRPatchCodeBytes(entry, patch, sizeof(patch), &patchError)) {
        gWCRCommentRepeatTrampoline = nullptr;
        gStringCopy = nullptr;
        gStringCopyCtor = nullptr;
        gStringDestroy = nullptr;
        gRecordAssign = nullptr;
        gWCRCommentRepeatStringFromQ = nullptr;
        gWCRCommentRepeatTextQ = nullptr;
        gWCRCommentRepeatShareCopy = nullptr;
        gWCRCommentRepeatConnectFn = nullptr;
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

BOOL WCRCommentRepeatUninstall(NSError **error) {
    gEnabled.store(false);
    if (!gInstalled.load()) return YES;

    NSError *patchError = nil;
    if (gBuilderEntry &&
        !WCRPatchCodeBytes(gBuilderEntry, gSavedPrologue, sizeof(gSavedPrologue), &patchError)) {
        if (error) *error = patchError;
        return NO;
    }
    if (gWCRCommentRepeatTrampoline) {
        mprotect(gWCRCommentRepeatTrampoline, kTrampolineBytes, PROT_READ | PROT_WRITE);
        munmap(gWCRCommentRepeatTrampoline, kTrampolineBytes);
        gWCRCommentRepeatTrampoline = nullptr;
    }
    gBuilderEntry = nullptr;
    gSlide.store(0);
    gInstalled.store(false);
    // gFree 留下。已经弹出的菜单销毁槽位时还要按 0x18 释放。
    LogLine(@"uninstall: ok");
    return YES;
}

BOOL WCRCommentRepeatIsInstalled(void) {
    return gInstalled.load();
}
