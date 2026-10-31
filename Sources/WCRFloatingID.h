#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 悬浮取 ID：聊天窗口右下角只显示一只小宠物，不把原始 ID 画出来。
/// 宠物是 JS 桌宠（眼睛跟着鼠标）。点按复制当前窗口的原始 ID。
/// 长按拖动；双击回到右下角。双击不改背景、大小和颜色。
/// 背景默认关闭。打开后是宠物后面的一块圆形液态玻璃（旧系统退回轻量磨砂）。
/// 字号只决定宠物大小。颜色是身体色相，默认停在原来的蓝。
/// 当前会话来自 WCROriginalID；全程 Cocoa，不触碰 Qt。
/// 调用方须在主线程；setEnabled(NO) 负责清理窗口与通知。

BOOL WCRFloatingIDSetEnabled(BOOL enabled);
BOOL WCRFloatingIDIsEnabled(void);

/// 没存过偏好时背景是关的。改完立刻作用到已经打开的浮窗。
BOOL WCRFloatingIDBackgroundEnabled(void);
void WCRFloatingIDSetBackgroundEnabled(BOOL enabled);

/// 默认 13。合法范围 9–28，超出的值会被收进来。
CGFloat WCRFloatingIDFontSize(void);
void WCRFloatingIDSetFontSize(CGFloat size);

/// 身体色相，单位度。没存过是原来的蓝（211.33）。合法范围 0–360。
CGFloat WCRFloatingIDHue(void);
void WCRFloatingIDSetHue(CGFloat hue);
/// 滑杆旁边的色块。默认色相返回原来的身体蓝，其它色相保持同样的明度。
NSColor *WCRFloatingIDHueColor(CGFloat hue);

NS_ASSUME_NONNULL_END
