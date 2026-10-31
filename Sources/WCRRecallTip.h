#import <Foundation/Foundation.h>

#import "WCRPatchProfiles.h"

NS_ASSUME_NONNULL_BEGIN

/// Installs the recall parser entry hook for builds that expose the optional
/// parseRevokeXML geometry in WCRPatchProfile. The caller must restore the
/// silent guard patch before installing this hook.
BOOL WCRRecallTipInstall(const WCRPatchProfile *profile, NSError **error);

/// Restores the original parser entry and releases the executable trampoline.
BOOL WCRRecallTipUninstall(NSError **error);

BOOL WCRRecallTipIsInstalled(void);

/// Newest-first events captured by the tip hook. Values are strings.
NSArray<NSDictionary<NSString *, NSString *> *> *WCRRecallTipRecentEvents(void);
void WCRRecallTipClearRecentEvents(void);

/// Tip text template. Supported variables: {name} {time} {content} {wxid}
/// {session}. Lines containing {content} are dropped entirely when content
/// display is disabled or the content is unavailable. The gray tip bubble is
/// rendered by WeChat itself, so font color cannot be changed — emoji are the
/// only way to add color.
NSString *WCRRecallTipDefaultTemplate(void);
NSString *WCRRecallTipStoredTemplate(void);
/// nil or an empty/whitespace string restores the default template.
void WCRRecallTipSetStoredTemplate(NSString * _Nullable templateString);

NS_ASSUME_NONNULL_END
