#import <Foundation/Foundation.h>

#import "WCRPatchProfiles.h"

NS_ASSUME_NONNULL_BEGIN

/// 退群监控（群成员退出/被移出群聊时，在聊天里留下灰字通知）。
///
/// 消息收口 Hook（messageFinalizerAddress）由 WCRMessageCapture 独占安装；
/// 观察者槽位由 WCRefineMac.mm 的统一分发器持有（转发给本模块的
/// WCRGroupLeaveOnMessage），两个消费方互不覆盖。Install/Uninstall 只做
/// 「启用标记 + 档案校验」，不改代码。观察者会改写退群消息的正文
/// std::string（与撤回提示同一做法），让灰字显示通知。

/// Whether the given profile carries the verified message-finalizer geometry
/// (messageFinalizerAddress + message type/content offsets) that 退群监控
/// consumes through the shared capture hook. Builds without it report NO —
/// per project policy we never guess addresses.
BOOL WCRGroupLeaveMonitorSupportsProfile(const WCRPatchProfile *profile);

/// 启用退群监控（校验档案几何信息并记住偏移）。真正的入口 Hook 由
/// WCRMessageCaptureInstall 负责，需配合菜单侧的 syncMessageCapture。
BOOL WCRGroupLeaveMonitorInstall(const WCRPatchProfile *profile, NSError **error);

/// 停用退群监控（清除启用标记；不动 Hook——Hook 归属消息捕获模块）。
BOOL WCRGroupLeaveMonitorUninstall(NSError **error);

BOOL WCRGroupLeaveMonitorIsInstalled(void);

/// 捕获点观察者入口：由 WCRefineMac.mm 的统一分发器（WCRMessageCaptureDispatch）
/// 转发调用；模块内部自行判断开关状态与消息类型，未启用时立即返回。
#if defined(__cplusplus)
extern "C" {
#endif
void WCRGroupLeaveOnMessage(const void *object);
#if defined(__cplusplus)
}
#endif

/// 聊天灰字的格式。变量：{name} 群昵称（有用户名时可点开资料页）
/// {time} 逃离时间（yyyy-MM-dd HH:mm:ss）{wxid} {group}。
/// 灰色气泡由微信渲染，不能改字体颜色。
NSString *WCRGroupLeaveDefaultTemplate(void);
NSString *WCRGroupLeaveStoredTemplate(void);
/// nil、空串或超长时恢复默认格式。
void WCRGroupLeaveSetStoredTemplate(NSString * _Nullable templateString);

NS_ASSUME_NONNULL_END
