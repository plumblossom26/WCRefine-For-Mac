#import <Foundation/Foundation.h>

#import "WCRPatchProfiles.h"

NS_ASSUME_NONNULL_BEGIN

/// Whether this build has a verified bubble-menu gate (voiceMenuGateAddress).
/// The send pipeline (voiceSendAddress and the three payload offsets) is a
/// separate entry and is still unregistered. Builds without the gate report
/// NO and the menu switch stays disabled.
BOOL WCRVoiceForwardSupportsProfile(const WCRPatchProfile *profile);

/// Patches the bubble-menu visibility gate so wire type 34 is shown the same
/// way type 1 is. Refuses without writing memory when the gate is missing,
/// wechat.dylib is not loaded, or the 16-byte prologue does not match.
BOOL WCRVoiceForwardInstall(const WCRPatchProfile *profile, NSError **error);

/// Restores the original gate entry and releases the trampoline.
BOOL WCRVoiceForwardUninstall(NSError **error);

BOOL WCRVoiceForwardIsInstalled(void);

NS_ASSUME_NONNULL_END
