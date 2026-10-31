#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Adds LC_LOAD_DYLIB to every arm64 slice in place.
///
/// The command is written into existing zero padding after the load commands,
/// so section and segment file offsets remain unchanged. Existing identical
/// load paths are accepted and leave the binary untouched.
BOOL WCRInjectDylibLoadCommand(NSString *binaryPath,
                               NSString *loadPath,
                               NSError **error);

/// Reads the XML entitlements embedded in the arm64 slice's code signature.
/// Missing entitlements are returned as an empty dictionary.
BOOL WCRReadExecutableEntitlements(NSString *binaryPath,
                                   NSDictionary<NSString *, id> * _Nullable * _Nonnull entitlements,
                                   NSError **error);

NS_ASSUME_NONNULL_END
