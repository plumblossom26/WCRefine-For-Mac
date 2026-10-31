#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Replaces one page of executable memory with a modified private copy.
/// This avoids vm_protect(VM_PROT_COPY) failures on current macOS releases.
BOOL WCRPatchCodeBytes(void *destination,
                       const void *bytes,
                       size_t length,
                       NSError **error);

NS_ASSUME_NONNULL_END
