#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 会话 ID 记录表：从消息捕获点（WCRMessageCapture）收到每条消息的对象指针，
/// 扫描对象上的 ID 形态字符串（群 @chatroom / wxid_ / gh_ / @openim），
/// 按“最近活跃”维护一张可点即复制的记录表，取代旧版注定失败的窗口文本扫描
/// ——微信 4.x 的 Qt UI 从不渲染 wxid 原始 ID，任何界面扫描都拿不到。

/// 消息捕获观察者：由 WCRefineMac.mm 启动时注册到 WCRMessageCapture。
/// object 是消息对象（类型/服务器ID/正文的宿主），只允许同步、快速、无副作用读取。
void WCROriginalIDObserveObject(const void *object);

/// 最近会话记录。当前打开的会话在最前面，其余按最后一条消息新→旧。
/// 每项：kind（群/用户/公众号/企业微信）、value、
/// lastSeen（显示时间字符串，当天 HH:mm，跨天 M/d HH:mm）、epoch、
/// front（@"1" 表示当前打开的会话）。
NSArray<NSDictionary<NSString *, NSString *> *> *WCROriginalIDRecentSessions(void);

/// 当前打开的会话原始 ID。没有选中过则为空，不用最后一条消息顶替。
NSString *WCROriginalIDFrontValue(void);

/// 当前登录账号的 wxid。优先用登录目录名，群消息里也会学到。没有则返回 nil。
NSString *_Nullable WCROriginalIDSelfWXID(void);

/// 选中会话变化，或清空记录后发出。object 为 nil，在主线程投递。
extern NSString *const WCROriginalIDFrontDidChangeNotification;

/// 聊天窗口选中的用户名（libc++ std::string*）。新会话会记入表，
/// 已有会话只固定到最上面，不改最后消息时间。空串和自己的 wxid 忽略。
/// C 链接：会话切换桩用 bl 按这个符号调用。
#ifdef __cplusplus
extern "C" {
#endif
void WCROriginalIDNoteSelectedUsername(const void *username);
#ifdef __cplusplus
}
#endif

/// 清空当前运行期的会话记录。
void WCROriginalIDClearSessions(void);

NS_ASSUME_NONNULL_END
