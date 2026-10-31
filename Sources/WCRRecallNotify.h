#import <Foundation/Foundation.h>

#import "WCRPatchProfiles.h"

NS_ASSUME_NONNULL_BEGIN

/// 撤回消息通知。和灰色提示分开：灰字仍由撤回提示模板渲染。
/// 这里只负责两件事，而且都要总开关打开才发：
/// 文字撤回按自定义格式发到所选会话和/或当前会话；其他支持类型调用微信原生转发。
/// 只支持 270135。发送函数的序言对不上就拒绝，不猜地址。
/// 触发点在撤回提示的去重之后，所以「显示撤回提示」要开着。自己撤回不发。

BOOL WCRRecallNotifySupportsProfile(const WCRPatchProfile * _Nullable profile);

/// 只解析并核对 270135 的转换、复制、析构、添加收件人、转发。不改微信代码。
BOOL WCRRecallNotifyPrepare(NSError * _Nullable * _Nullable error);
BOOL WCRRecallNotifyIsReady(void);

/// 总开关。缺省关闭。子开关可以先勾好，总开关关闭时不发送。
BOOL WCRRecallNotifyMasterEnabled(void);
void WCRRecallNotifySetMasterEnabled(BOOL enabled);

/// 缺省打开，但只有总开关打开才发。
BOOL WCRRecallNotifySelfEnabled(void);
void WCRRecallNotifySetSelfEnabled(BOOL enabled);

/// “通知给自己”的接收会话。空字符串表示自己的会话；也可以选一个好友或群。
/// 文字消息直接发一条文字通知到该会话，其他支持的类型用微信原生转发到该会话。
NSString *WCRRecallNotifyTargetSession(void);
/// 传 nil/空串恢复“给自己”。非法会话 ID 返回 NO，且不覆盖现有选择。
BOOL WCRRecallNotifySetTargetSession(NSString * _Nullable session);

/// 缺省关闭。当前会话是撤回 XML 里的 session，不是最近一个聊天。
BOOL WCRRecallNotifySessionEnabled(void);
void WCRRecallNotifySetSessionEnabled(BOOL enabled);

/// 缺省关闭。把撤回前捕获到的原消息交给微信原生转发，发给自己。
/// 支持文字/图片/语音/名片/视频/表情/位置/appmsg。不转发撤回系统消息，
/// 也不按原服务器 ID 转发。
BOOL WCRRecallNotifyForwardSelfEnabled(void);
void WCRRecallNotifySetForwardSelfEnabled(BOOL enabled);

/// 总开关打开，且三个去向里至少有一个打开。这时才需要消息收口钩子。
BOOL WCRRecallNotifyWantsCapture(void);

/// 关掉不需要的快照。文字外壳和原消息快照分开丢。
void WCRRecallNotifyReleaseHeldMessages(void);

/// 占位符：{name} {time} {content} {wxid} {session}。
/// 内容为空时丢掉含 {content} 的整行。不附加灰色提示用的零宽哨兵。
NSString *WCRRecallNotifyDefaultTemplate(void);
NSString *WCRRecallNotifyStoredTemplate(void);
void WCRRecallNotifySetStoredTemplate(NSString * _Nullable templateString);

/// 消息收口观察者。必须同步返回，不能把对象指针留到别的线程。
void WCRRecallNotifyObserveWrap(const void * _Nullable wrap);

/// 一条非自己的撤回第一次被记下时调用。内部再派发到主线程发送。
void WCRRecallNotifyOnUniqueRecall(NSString * _Nullable name,
                                   NSString * _Nullable timeText,
                                   NSString * _Nullable content,
                                   NSString * _Nullable wxid,
                                   NSString * _Nullable session,
                                   uint64_t serverID);

/// 退群文字通知复用同一套 270135 文字外壳和发送链。两个去向默认关闭。
BOOL WCRRecallNotifyLeaveSessionEnabled(void);
void WCRRecallNotifySetLeaveSessionEnabled(BOOL enabled);
BOOL WCRRecallNotifyLeaveSelfEnabled(void);
void WCRRecallNotifySetLeaveSelfEnabled(BOOL enabled);
BOOL WCRRecallNotifyLeaveWantsCapture(void);
void WCRRecallNotifySetLeaveMonitorActive(BOOL active);

/// 退群事件解析完成后调用。groupID 为空时仍可发给自己。
void WCRRecallNotifySendLeaveText(NSString * _Nullable body,
                                  NSString * _Nullable groupID);

/// 单测入口。不读用户默认值，也不调用微信发送函数。
NSString *WCRRecallNotifyRenderForTesting(NSString * _Nullable templateString,
                                          NSString * _Nullable name,
                                          NSString * _Nullable timeText,
                                          NSString * _Nullable content,
                                          NSString * _Nullable wxid,
                                          NSString * _Nullable session);
BOOL WCRRecallNotifyRecipientAllowedForTesting(NSString * _Nullable value);
BOOL WCRRecallNotifyBodyIsNormalForwardForTesting(NSString * _Nullable body);

NS_ASSUME_NONNULL_END
