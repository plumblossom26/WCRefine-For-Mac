#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 从最近会话和已经见过的联系人里多选，结果写到撤回通知的指定联系人。
/// 也可以手填用户名。不打开微信数据库。
void WCRContactPickerPresentForNotify(void);

/// 合并最近会话、已知名称和当前勾选，供选择器与离线测试共用。
NSMutableArray<NSMutableDictionary<NSString *, id> *> *WCRContactPickerBuildRows(
    NSArray<NSDictionary<NSString *, id> *> *recentSessions,
    NSArray<NSDictionary<NSString *, id> *> *records,
    NSArray<NSString *> *notifyUserNames);

/// 选择器点「完成」之后发出。菜单据此重装撤回通知的文字外壳。
FOUNDATION_EXPORT NSString *const WCRNotifyContactsDidChangeNotification;

NS_ASSUME_NONNULL_END
