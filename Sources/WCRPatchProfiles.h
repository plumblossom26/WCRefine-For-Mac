#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WCRPatchState) {
    WCRPatchStateUnavailable = 0,
    WCRPatchStatePristine,
    WCRPatchStateApplied,
    WCRPatchStateInvalidBytes,
};

typedef struct {
    const char *shortVersion;
    const char *buildVersion;
    const char *displayVersion;
    /// Full-file SHA-256 of Contents/Resources/wechat.dylib.
    /// Version strings alone are not sufficient to identify a build.
    const char *dylibSHA256;
    uint64_t patchAddress;
    uint8_t expectedBytes[4];
    uint8_t replacementBytes[4];

    /// Optional parseRevokeXML entry and message layout for recall-tip mode.
    /// Zero means this build only supports silent anti-revoke.
    uint64_t revokeParserAddress;
    uint32_t revokePrologue[4];
    uint64_t revokeNewMsgIdOffset;
    uint64_t revokeReplaceMsgOffset;

    /// Optional common-message finalizer geometry for capturing the original
    /// content before a later revoke event arrives.
    uint64_t messageFinalizerAddress;
    uint64_t messageFinalizerContinuation;
    uint32_t messageFinalizerPrologue[4];
    uint64_t messageServerIDOffset;
    uint64_t messageTypeOffset;
    uint64_t messageContentOffset;
    /// 0 = 本构建还没核实。这是 0x278 聊天消息的时间，不是撤回解析参数。
    /// 270135 构造函数 0x4cbb198：秒在 +0x114，同一时刻的毫秒在 +0x100。
    /// 捕获原消息时间用它们。解析对象把 revoketime 放在 +0x288，不能写这里。
    uint64_t messageCreateTimeSecOffset;
    uint64_t messageCreateTimeMsOffset;
    /// 0 = 只写 revokeReplaceMsgOffset。270135 带 <revoketime> 时，
    /// parseRevokeXML 把 <content> 写入 +0x1D0 后再赋给这两处
    /// （0x4d20524、0x4d20530）。灰字读的是这两份。
    uint64_t revokeDisplayCopyOffsetA;
    uint64_t revokeDisplayCopyOffsetB;

    /// Voice send pipeline. Still unregistered on every build: the bubble
    /// switch does not read these fields. Offsets stay zero until a
    /// prologue-checked send entry exists. Do not invent them.
    uint64_t voiceSendAddress;
    uint32_t voiceSendPrologue[4];
    uint64_t voiceDataOffset;
    uint64_t voiceDurationOffset;
    uint64_t voiceFormatOffset;

    /// Bubble-menu visibility gate for type 34. Zero means this build has no
    /// verified gate and the switch stays disabled. 270135: sub_4D3AE38.
    /// x0 is the menu view-model (menu+0x120); the wire type dword is at +8.
    /// Text type 1 returns 1. Voice type 34 falls through to return 0.
    /// The hook returns 1 only for type 34. This is not voiceSendAddress.
    uint64_t voiceMenuGateAddress;
    uint32_t voiceMenuGatePrologue[4];

    /// Optional text-message long-press menu builder for 消息复读.
    /// 270135: 0xcf46ac (BuildMenu). Zero on other builds: helper entry points
    /// used by the feature are version-specific and must not be guessed.
    uint64_t repeatMenuBuilderAddress;
    uint32_t repeatMenuBuilderPrologue[4];

    /// Optional avatar paint entry for 圆角头像. Zero means this build has no
    /// verified entry yet: the feature
    /// stays preference-only and the hook refuses to install. The entry is
    /// Shared XImage bitmap paint (270135: 0x1f3c2cc). The hook keeps the
    /// avatar percent on XAvatarImage, ContactHeadView and SNSAvatarHeadView
    /// only. It reads mode at widget+468 (2=circle) and radii at +472/+476.
    /// 100% forces mode 2; smaller percents use mode 1.
    uint64_t avatarShapeAddress;
    uint32_t avatarShapePrologue[4];

    /// ChatMasterView::OnSelectedSession(std::string) 发射桩。
    /// 270135: 0x1361b8。x0 是视图，x1 是用户名 std::string*。
    /// 前 3 条指令可搬走，第 4 条是 adrp，必须留在原地。其它构建为 0。
    uint64_t sessionSelectAddress;
    uint32_t sessionSelectPrologue[3];
} WCRPatchProfile;

typedef struct {
    BOOL supported;
    BOOL alreadyPatched;
    WCRPatchProfile profile;
    NSString *shortVersion;
    NSString *buildVersion;
    NSString *wechatDylibPath;
    NSString *failureReason;
} WCRAppInspection;

/// Reads a WeChat.app without loading it.
/// Returns NO only for hard errors: missing Info.plist, not WeChat,
/// missing wechat.dylib, not arm64, or unreadable Mach-O.
/// Unknown CFBundleVersion and patch-byte mismatch set supported=NO
/// and failureReason, then return YES so the installer can still copy.
BOOL WCRInspectWeChatApp(NSString *appPath, WCRAppInspection *inspection, NSError **error);

/// Returns the version profile for the current WeChat process.
const WCRPatchProfile * _Nullable WCRCurrentProcessProfile(NSError **error);

/// 主副本 bundle id 是 com.tencent.xinWeChat。多开副本是
/// com.tencent.xinWeChat.WCRefineMulti<N>，插件必须同样放行。
/// selfTest 为真时另外接受 com.tencent.xinWeChat.WCRefineTest 前缀。
BOOL WCRHostBundleIdentifierAllowed(NSString *bundleIdentifier, BOOL selfTest);

/// Applies or restores the memory-only patch in the current WeChat process.
BOOL WCRApplyAntiRevokePatch(NSError **error);
BOOL WCRRestoreAntiRevokePatch(NSError **error);

/// Reports the real bytes currently present in the loaded wechat.dylib.
WCRPatchState WCRCurrentProcessPatchState(NSError **error);

/// Human-readable support list for the CLI and diagnostics.
NSArray<NSString *> *WCRSupportedBuildDescriptions(void);

NS_ASSUME_NONNULL_END
