#import <Foundation/Foundation.h>
#import <sys/utsname.h>

#import "../Sources/WCRPatchProfiles.h"

static void WCRPrintUsage(void) {
    fprintf(stderr, "Usage: wcrefine-check --app /Applications/WeChat.app\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *appPath = @"/Applications/WeChat.app";
        for (int i = 1; i < argc; ++i) {
            NSString *argument = @(argv[i]);
            if ([argument isEqualToString:@"--app"] && i + 1 < argc) {
                appPath = @(argv[++i]);
            } else if ([argument isEqualToString:@"--help"] || [argument isEqualToString:@"-h"]) {
                WCRPrintUsage();
                return 0;
            } else {
                WCRPrintUsage();
                return 1;
            }
        }

        struct utsname systemInfo{};
        if (uname(&systemInfo) != 0 || strcmp(systemInfo.machine, "arm64") != 0) {
            fprintf(stderr, "error: 当前仅支持 Apple Silicon（arm64）\n");
            return 2;
        }

        WCRAppInspection inspection{};
        NSError *error = nil;
        if (!WCRInspectWeChatApp(appPath, &inspection, &error)) {
            fprintf(stderr, "error: %s\n", error.localizedDescription.UTF8String ?: "unknown error");
            fprintf(stderr, "supported:\n");
            for (NSString *row in WCRSupportedBuildDescriptions()) {
                fprintf(stderr, "  - %s\n", row.UTF8String);
            }
            return 2;
        }

        printf("supported=%s\n", inspection.supported ? "yes" : "no");
        printf("version=%s\n", inspection.shortVersion.UTF8String ?: "");
        printf("build=%s\n", inspection.buildVersion.UTF8String ?: "");
        if (inspection.supported) {
            printf("state=%s\n", inspection.alreadyPatched ? "already-patched" : "pristine");
            if (inspection.profile.patchAddress == 0) {
                printf("note=防撤回补丁点未登记\n");
            }
        } else if (inspection.failureReason.length) {
            printf("note=%s\n", inspection.failureReason.UTF8String);
        }
        return inspection.supported ? 0 : 1;
    }
}
