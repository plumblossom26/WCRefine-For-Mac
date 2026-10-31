#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 配置是一份带 schema 和 revision 的属性列表，不是数据库。
/// 导入先整份校验，不通过就不改现有设置。通过之后先备份，再合并。
FOUNDATION_EXPORT NSInteger const WCRConfigSchemaVersion;

NSInteger WCRConfigStoreRevision(void);
void WCRConfigStoreBumpRevision(void);

NSDictionary *WCRConfigStoreDocument(NSString * _Nullable pluginVersion);
/// 校验失败时返回 NO，并且不写 defaults、不换联系人缓存。
BOOL WCRConfigStoreImportDocument(NSDictionary *document, NSError * _Nullable * _Nullable error);

void WCRConfigStorePresentExport(NSString *pluginVersion);
void WCRConfigStorePresentImport(void);

FOUNDATION_EXPORT NSString *const WCRConfigDidImportNotification;

NS_ASSUME_NONNULL_END
