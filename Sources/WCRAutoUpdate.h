#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 微信 4.1 更新走 Sparkle（SPUUpdater / SUUpdater / SPUStandardUpdaterController）。
/// 开启后关掉自动检查和自动下载，定时器到点不再查。
/// 菜单里的「检查更新」同样不执行：checkForUpdates 和 checkForUpdates: 直接返回。
/// 不改安全模式（mmui::SafeModeWindow）和 crashpad 崩溃日志。

/// 安装 Sparkle 钩子。可重复调用。Sparkle 晚加载时会再试。
void WCRAutoUpdateInstall(void);

/// 打开后禁止自动检查、自动下载、到点的后台检查，以及手动检查更新。
void WCRAutoUpdateSetEnabled(BOOL enabled);

BOOL WCRAutoUpdateIsEnabled(void);

/// 启动重试：updater 可能晚于插件创建。只在开关开着时重申。
void WCRAutoUpdateApply(void);

NS_ASSUME_NONNULL_END
