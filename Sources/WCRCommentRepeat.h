#import <Foundation/Foundation.h>

#import "WCRPatchProfiles.h"

NS_ASSUME_NONNULL_BEGIN

/// 朋友圈评论复读。270351 的评论长按菜单在原菜单返回后把「复读」放到第一项。
/// 点击后走微信自己的评论发送入口，把这条评论的文字再发到同一条朋友圈。
/// 不走聊天消息转发。没有登记入口的构建（含 270135）开关保持关闭。
BOOL WCRCommentRepeatSupportsProfile(const WCRPatchProfile * _Nullable profile);
BOOL WCRCommentRepeatInstall(const WCRPatchProfile *profile, NSError **error);
BOOL WCRCommentRepeatUninstall(NSError **error);
BOOL WCRCommentRepeatIsInstalled(void);

NS_ASSUME_NONNULL_END
