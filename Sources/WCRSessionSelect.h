#import <Foundation/Foundation.h>

#import "WCRPatchProfiles.h"

NS_ASSUME_NONNULL_BEGIN

/// 270135：mmui::ChatMasterView::OnSelectedSession(std::string)。
/// 打开哪个聊天窗口，就把那个会话的原始 ID 固定到列表最上面。
/// 其它构建地址为 0，安装直接拒绝，不猜测。
BOOL WCRSessionSelectInstall(const WCRPatchProfile *profile, NSError **error);
BOOL WCRSessionSelectUninstall(NSError **error);
BOOL WCRSessionSelectIsInstalled(void);

NS_ASSUME_NONNULL_END
