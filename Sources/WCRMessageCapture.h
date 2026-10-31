#import <Foundation/Foundation.h>

#import "WCRPatchProfiles.h"

NS_ASSUME_NONNULL_BEGIN

/// 是否登记了消息终结器几何信息（messageFinalizerAddress 等）。
/// 零值 = 未登记 = 不安装。
BOOL WCRMessageCaptureSupportsProfile(const WCRPatchProfile *profile);

/// 在消息终结器入口安装捕获跳板：每条消息进入终结器时记录
/// （serverID → 类型）；提示模式开启时另存正文，供撤回提示反查原消息内容。
/// 安装前校验入口 prologue 字节，不匹配即拒绝（不写任何内存）。
BOOL WCRMessageCaptureInstall(const WCRPatchProfile *profile, NSError **error);

BOOL WCRMessageCaptureUninstall(NSError **error);

BOOL WCRMessageCaptureIsInstalled(void);

/// 开关正文捕获，默认关闭。关闭时清空已捕获正文，但仍保留类型和服务器 ID。
void WCRMessageCaptureSetContentCaptureEnabled(BOOL enabled);

/// 捕获点观察者：每条进入终结器的消息都会以 x0（消息对象）回调一次。
/// 必须同步、快速、不得抛异常；在 hook 未安装前注册也安全。
typedef void (*WCRMessageCaptureObjectObserver)(const void *object);
void WCRMessageCaptureSetObjectObserver(WCRMessageCaptureObjectObserver _Nullable observer);

/// 撤回提示反查：按服务器消息 ID 取捕获到的正文（nil = 没有捕获到）。
NSString * _Nullable WCRMessageCaptureContent(uint64_t serverID);

/// 撤回提示反查：按服务器消息 ID 取捕获到的消息类型（0 = 没有捕获到）。
NSUInteger WCRMessageCaptureType(uint64_t serverID);

/// 撤回提示反查：原消息的发送时间（Unix 秒）。0 = 没捕获到，或本构建没登记偏移。
uint32_t WCRMessageCaptureCreateTime(uint64_t serverID);

NS_ASSUME_NONNULL_END
