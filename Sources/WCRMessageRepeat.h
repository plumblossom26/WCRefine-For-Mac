#import <Foundation/Foundation.h>

#import "WCRPatchProfiles.h"

NS_ASSUME_NONNULL_BEGIN

/// 消息复读：在 270135 的消息长按菜单顶部追加「复读」。
/// 构建菜单时复制当前 MessageData 快照，点击后交给微信原生转发提交链，
/// 将文字、语音、图片、视频、文件/链接、表情等原消息发回当前会话。
BOOL WCRMessageRepeatSupportsProfile(const WCRPatchProfile * _Nullable profile);
BOOL WCRMessageRepeatInstall(const WCRPatchProfile *profile, NSError **error);
BOOL WCRMessageRepeatUninstall(NSError **error);
BOOL WCRMessageRepeatIsInstalled(void);

NS_ASSUME_NONNULL_END
