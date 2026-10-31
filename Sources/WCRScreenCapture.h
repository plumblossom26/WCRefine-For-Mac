#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 微信「演示时隐藏主窗口」走 device_util_mac.mm 的 SetWindowSharingPolicy：
/// policy 1 → setSharingType:NSWindowSharingNone，policy 0 → ReadOnly。
/// 另一处截图遮罩会先把窗口抬到 NSStatusWindowLevel 再设 None，那条不拦。

/// 安装 NSWindow setSharingType: 钩子。可重复调用。
void WCRScreenCaptureInstall(void);

/// 打开后，普通层级窗口上的 NSWindowSharingNone 会被改成 ReadOnly，
/// 系统截图、录屏和屏幕共享能看到微信主窗口。
void WCRScreenCaptureSetBypassEnabled(BOOL enabled);

BOOL WCRScreenCaptureIsBypassEnabled(void);

/// 把已经是 None 的普通窗口改成 ReadOnly。钩子晚于设值时用。
void WCRScreenCaptureApplyVisibleWindows(void);

NS_ASSUME_NONNULL_END
