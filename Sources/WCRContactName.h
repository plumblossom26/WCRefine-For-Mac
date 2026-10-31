#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 撤回提示、退群提示和通知共用的名称。
/// 自动顺序：备注、这次看到的名字、群昵称、昵称、微信号、用户名。
/// 指定某一种时先用那一种，空了再按上面的顺序兜底。
/// 不读 contact.db。名字只来自已经见过的消息，以及选择器里手填的备注。
typedef NS_ENUM(NSInteger, WCRContactNameStyle) {
    WCRContactNameStyleAuto = 0,
    WCRContactNameStyleRemark = 1,
    WCRContactNameStyleGroupNickname = 2,
    WCRContactNameStyleNickname = 3,
    WCRContactNameStyleAlias = 4,
    WCRContactNameStyleWxid = 5,
};

WCRContactNameStyle WCRContactNameCurrentStyle(void);
void WCRContactNameSetStyle(WCRContactNameStyle style);
/// 导入配置后丢掉缓存，下次按 defaults 里的样式再读。
void WCRContactNameReloadStyle(void);

/// 当前这条消息上的名字。observed 是微信原文里已经显示的那个。
/// 没有备注时，自动样式原样返回 observed，避免把提示改成 wxid。
NSString *WCRContactNamePreferred(NSString * _Nullable userName,
                                  NSString * _Nullable observed);

/// 用这条消息里的群名片、昵称覆盖缓存里的对应字段，再按当前样式取值。
NSString *WCRContactNameResolve(NSString * _Nullable userName,
                                NSString * _Nullable groupNickname,
                                NSString * _Nullable nickname,
                                NSString * _Nullable observed);

/// 记下见过的人。空字段不覆盖已有值。备注只在传入非空时更新。
/// 只在微信进程里写磁盘。
void WCRContactNameRemember(NSString * _Nullable userName,
                            NSString * _Nullable remark,
                            NSString * _Nullable groupNickname,
                            NSString * _Nullable nickname,
                            NSString * _Nullable alias);

NSString *WCRContactNameDisplay(NSString * _Nullable userName);

NSArray<NSDictionary<NSString *, NSString *> *> *WCRContactNameRecords(void);

/// 选择器里改备注、或导入配置时整表替换。
void WCRContactNameReplaceRecords(NSArray<NSDictionary<NSString *, NSString *> *> *records);

BOOL WCRContactNameNotifyEnabled(void);
void WCRContactNameSetNotifyEnabled(BOOL enabled);
NSArray<NSString *> *WCRContactNameNotifyUserNames(void);
void WCRContactNameSetNotifyUserNames(NSArray<NSString *> * _Nullable userNames);

/// 测试用。不写磁盘，也不看 bundle id。
void WCRContactNameResetForTesting(void);
void WCRContactNameRememberForTesting(NSString * _Nullable userName,
                                     NSString * _Nullable remark,
                                     NSString * _Nullable groupNickname,
                                     NSString * _Nullable nickname,
                                     NSString * _Nullable alias);

NS_ASSUME_NONNULL_END
