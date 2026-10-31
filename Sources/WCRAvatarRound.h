#import <Foundation/Foundation.h>

#import "WCRPatchProfiles.h"

NS_ASSUME_NONNULL_BEGIN

/// 圆角头像的圆角大小（百分比 0–100）。100 = 纯圆（短边的一半），数值越小
/// 越接近方形，0 = 直角方形。公式与手机版 WCRefine 一致。未设置或越界时返回 100。
/// 存储键：WCRefineMacAvatarRadiusPercent。
NSInteger WCRAvatarRoundRadiusPercent(void);
void WCRAvatarRoundSetRadiusPercent(NSInteger percent);

/// Whether the given profile carries a verified avatar paint entry
/// (avatarShapeAddress). Builds without that entry report NO — per project
/// policy we never guess addresses, so 圆角头像 stays preference-only until
/// the reverse-engineered entry is registered in WCRPatchProfiles.mm.
BOOL WCRAvatarRoundSupportsProfile(const WCRPatchProfile *profile);

/// Installs the avatar mask hook for the current process profile when that
/// profile exposes avatar geometry. Refuses (without writing any memory) when
/// the geometry is missing or the entry prologue bytes no longer match the
/// running wechat.dylib.
BOOL WCRAvatarRoundInstall(NSError **error);

/// Restores the original avatar cache entry and releases the hook.
BOOL WCRAvatarRoundUninstall(NSError **error);

BOOL WCRAvatarRoundIsInstalled(void);

/// 从 NSUserDefaults 重读头像圆角开关与百分比到钩子用的原子缓存（菜单变更后调用）。
void WCRAvatarRoundRefreshPrefs(void);

NS_ASSUME_NONNULL_END
