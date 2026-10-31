#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WCRInstallProgressBlock)(NSString *message);

/// Copies WeChat to destination, adds WCRefineMac.dylib, then ad-hoc signs
/// the copy. The source application is never modified.
BOOL WCRInstallEnhancedCopy(NSURL *sourceApp,
                            NSURL *destinationApp,
                            NSString *dylibPath,
                            BOOL replaceExisting,
                            WCRInstallProgressBlock _Nullable progress,
                            NSError **error);

/// Same as WCRInstallEnhancedCopy, with optional overrides for building
/// 多开 (multi-instance) copies. A distinct CFBundleIdentifier makes macOS
/// assign the copy its own sandbox container, so it can run alongside the
/// original WeChat and the main copy without contending for the same data
/// directory. Pass nil/empty to keep the source bundle identifier and the
/// default "WCRefine 微信" display name (main-copy behavior).
BOOL WCRInstallEnhancedCopyWithOptions(NSURL *sourceApp,
                                       NSURL *destinationApp,
                                       NSString *dylibPath,
                                       NSString * _Nullable bundleIdentifier,
                                       NSString * _Nullable displayName,
                                       BOOL replaceExisting,
                                       WCRInstallProgressBlock _Nullable progress,
                                       NSError **error);

NSURL *WCRDefaultEnhancedAppURL(void);

/// ~/Applications/WCRefine-WeChat-<instanceNumber>.app
NSURL *WCRDefaultMultiInstanceAppURL(NSUInteger instanceNumber);

/// com.tencent.xinWeChat.WCRefineMulti<instanceNumber>
NSString *WCRMultiInstanceBundleIdentifier(NSUInteger instanceNumber);

/// Smallest unused instance number (>= 2), judged by the copies already
/// present in ~/Applications; 0 when none is available.
NSUInteger WCRNextMultiInstanceNumber(void);

NS_ASSUME_NONNULL_END
