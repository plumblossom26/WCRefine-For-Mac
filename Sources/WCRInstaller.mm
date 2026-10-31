#import "WCRInstaller.h"

#import "WCRMachOInjector.h"
#import "WCRPatchProfiles.h"

#import <AppKit/AppKit.h>

#include <cerrno>
#include <cstring>

static NSString *const kWCRLoadPath = @"@executable_path/../Resources/WCRefineMac.dylib";
static NSString *const kWCROutputAppName = @"WCRefine-WeChat.app";

static NSError *WCRInstallError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMac.Installer"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"未知安装错误"}];
}

static void WCRReport(WCRInstallProgressBlock progress, NSString *message) {
    if (progress) progress(message);
}

static BOOL WCRRunProcess(NSString *launchPath,
                          NSArray<NSString *> *arguments,
                          NSError **error) {
    NSString *logPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"wcrefine-process-%@.log",
                                                                 [[NSUUID UUID] UUIDString]]];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager createFileAtPath:logPath contents:[NSData data] attributes:nil]) {
        if (error) *error = WCRInstallError(@"无法创建签名日志");
        return NO;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:launchPath];
    task.arguments = arguments;
    NSFileHandle *logHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!logHandle) {
        [fileManager removeItemAtPath:logPath error:nil];
        if (error) *error = WCRInstallError(@"无法打开签名日志");
        return NO;
    }
    task.standardOutput = logHandle;
    task.standardError = logHandle;

    NSError *launchError = nil;
    BOOL launched = [task launchAndReturnError:&launchError];
    if (launched) [task waitUntilExit];
    [logHandle closeFile];

    NSData *logData = [NSData dataWithContentsOfFile:logPath];
    NSString *log = [[NSString alloc] initWithData:logData ?: [NSData data]
                                           encoding:NSUTF8StringEncoding] ?: @"";
    [fileManager removeItemAtPath:logPath error:nil];

    if (!launched) {
        if (error) {
            *error = WCRInstallError([NSString stringWithFormat:@"无法启动 %@: %@",
                launchPath.lastPathComponent,
                launchError.localizedDescription ?: @"未知错误"]);
        }
        return NO;
    }
    if (task.terminationStatus != 0) {
        NSString *trimmed = log;
        if (trimmed.length > 3000) {
            trimmed = [trimmed substringFromIndex:trimmed.length - 3000];
        }
        if (error) {
            *error = WCRInstallError([NSString stringWithFormat:@"%@ 失败（%d）%@",
                launchPath.lastPathComponent,
                task.terminationStatus,
                trimmed.length ? [@"\n" stringByAppendingString:trimmed] : @""]);
        }
        return NO;
    }
    return YES;
}

static BOOL WCRCopyItem(NSURL *source, NSURL *destination, NSError **error) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:destination.path]) {
        if (![fileManager removeItemAtURL:destination error:error]) return NO;
    }
    return [fileManager copyItemAtURL:source toURL:destination error:error];
}



static BOOL WCRResignNestedApp(NSString *appPath, WCRInstallProgressBlock progress,
                                 NSError **error) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *infoPath = [appPath stringByAppendingPathComponent:@"Contents/Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
    NSString *executable = info[@"CFBundleExecutable"];
    if (executable.length == 0) {
        if (error) *error = WCRInstallError([NSString stringWithFormat:@"辅助组件缺少可执行文件: %@", appPath]);
        return NO;
    }
    NSString *binaryPath = [[appPath stringByAppendingPathComponent:@"Contents/MacOS"]
        stringByAppendingPathComponent:executable];
    NSDictionary<NSString *, id> *entitlements = nil;
    if (!WCRReadExecutableEntitlements(binaryPath, &entitlements, error)) return NO;
    if (entitlements.count == 0) {
        if (error) *error = WCRInstallError([NSString stringWithFormat:@"辅助组件缺少权限: %@", appPath]);
        return NO;
    }
    NSError *plistError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:entitlements
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&plistError];
    if (!data) {
        if (error) *error = plistError ?: WCRInstallError(@"无法编码辅助组件权限");
        return NO;
    }
    NSString *temporary = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"wcrefine-nested-%@.plist",
                                                                 [[NSUUID UUID] UUIDString]]];
    if (![data writeToFile:temporary atomically:YES]) {
        if (error) *error = WCRInstallError(@"无法写入辅助组件权限");
        return NO;
    }
    WCRReport(progress, [NSString stringWithFormat:@"重签%@…", appPath.lastPathComponent]);
    BOOL signedOK = WCRRunProcess(@"/usr/bin/codesign",
                                  @[@"--force", @"--sign", @"-",
                                    @"--entitlements", temporary,
                                    @"--timestamp=none", appPath],
                                  error);
    [fileManager removeItemAtPath:temporary error:nil];
    if (!signedOK) return NO;
    return WCRRunProcess(@"/usr/bin/codesign",
                         @[@"--verify", @"--strict", appPath], error);
}

NSURL *WCRDefaultEnhancedAppURL(void) {
    NSURL *applications = [[NSFileManager defaultManager]
        URLsForDirectory:NSApplicationDirectory
               inDomains:NSUserDomainMask].firstObject;
    if (!applications) {
        applications = [NSURL fileURLWithPath:[NSHomeDirectory()
            stringByAppendingPathComponent:@"Applications"]];
    }
    return [applications URLByAppendingPathComponent:kWCROutputAppName];
}

static NSURL *WCRApplicationsDirectory(void) {
    NSURL *applications = [[NSFileManager defaultManager]
        URLsForDirectory:NSApplicationDirectory
               inDomains:NSUserDomainMask].firstObject;
    if (!applications) {
        applications = [NSURL fileURLWithPath:[NSHomeDirectory()
            stringByAppendingPathComponent:@"Applications"]];
    }
    return applications;
}

NSURL *WCRDefaultMultiInstanceAppURL(NSUInteger instanceNumber) {
    NSString *name = [NSString stringWithFormat:@"WCRefine-WeChat-%lu.app",
                                                               (unsigned long)instanceNumber];
    return [WCRApplicationsDirectory() URLByAppendingPathComponent:name];
}

NSString *WCRMultiInstanceBundleIdentifier(NSUInteger instanceNumber) {
    return [NSString stringWithFormat:@"com.tencent.xinWeChat.WCRefineMulti%lu",
                                      (unsigned long)instanceNumber];
}

NSUInteger WCRNextMultiInstanceNumber(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSUInteger number = 2; number <= 99; ++number) {
        if (![fileManager fileExistsAtPath:WCRDefaultMultiInstanceAppURL(number).path]) {
            return number;
        }
    }
    return 0;
}

BOOL WCRInstallEnhancedCopy(NSURL *sourceApp,
                            NSURL *destinationApp,
                            NSString *dylibPath,
                            BOOL replaceExisting,
                            WCRInstallProgressBlock progress,
                            NSError **error) {
    return WCRInstallEnhancedCopyWithOptions(sourceApp,
                                             destinationApp,
                                             dylibPath,
                                             nil,
                                             nil,
                                             replaceExisting,
                                             progress,
                                             error);
}

BOOL WCRInstallEnhancedCopyWithOptions(NSURL *sourceApp,
                                       NSURL *destinationApp,
                                       NSString *dylibPath,
                                       NSString *bundleIdentifier,
                                       NSString *displayName,
                                       BOOL replaceExisting,
                                       WCRInstallProgressBlock progress,
                                       NSError **error) {
    if (!sourceApp || !destinationApp || dylibPath.length == 0) {
        if (error) *error = WCRInstallError(@"安装参数不完整");
        return NO;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *sourcePath = sourceApp.URLByResolvingSymlinksInPath.URLByStandardizingPath.path;
    NSString *destinationPath = destinationApp.URLByStandardizingPath.path;
    sourceApp = [NSURL fileURLWithPath:sourcePath isDirectory:YES];
    destinationApp = [NSURL fileURLWithPath:destinationPath isDirectory:YES];

    if ([sourcePath isEqualToString:destinationPath]) {
        if (error) *error = WCRInstallError(@"源应用与目标应用不能相同");
        return NO;
    }
    if (![fileManager fileExistsAtPath:sourcePath isDirectory:nil]) {
        if (error) *error = WCRInstallError([NSString stringWithFormat:@"找不到微信: %@", sourcePath]);
        return NO;
    }
    if (![fileManager fileExistsAtPath:dylibPath isDirectory:nil]) {
        if (error) *error = WCRInstallError([NSString stringWithFormat:@"找不到插件: %@", dylibPath]);
        return NO;
    }
    if ([fileManager fileExistsAtPath:destinationPath] && !replaceExisting) {
        if (error) *error = WCRInstallError([NSString stringWithFormat:@"目标已存在: %@", destinationPath]);
        return NO;
    }

    WCRAppInspection inspection{};
    NSError *inspectError = nil;
    if (!WCRInspectWeChatApp(sourcePath, &inspection, &inspectError)) {
        if (error) *error = inspectError ?: WCRInstallError(@"微信兼容性检查失败");
        return NO;
    }

    NSString *versionLabel = inspection.shortVersion.length ? inspection.shortVersion : @"未知版本";
    NSString *buildLabel = inspection.buildVersion.length ? inspection.buildVersion : @"?";
    if (inspection.supported) {
        NSString *display = inspection.profile.displayVersion
            ? @(inspection.profile.displayVersion)
            : versionLabel;
        WCRReport(progress, [NSString stringWithFormat:@"已识别微信 %@（%@）", display, buildLabel]);
    } else {
        WCRReport(progress, [NSString stringWithFormat:@"微信 %@（%@）未完全匹配，仍继续安装",
                                                       versionLabel, buildLabel]);
        if (inspection.failureReason.length) {
            WCRReport(progress, inspection.failureReason);
        }
    }

    NSURL *parent = destinationApp.URLByDeletingLastPathComponent;
    if (![fileManager createDirectoryAtURL:parent
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:error]) {
        return NO;
    }

    NSString *temporaryName = [NSString stringWithFormat:@".%@.wcrefine-%@.app",
        destinationApp.lastPathComponent, [[NSUUID UUID] UUIDString]];
    NSURL *temporaryApp = [parent URLByAppendingPathComponent:temporaryName isDirectory:YES];
    NSURL *temporaryEntitlements = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"wcrefine-entitlements-%@.plist",
                                                                 [[NSUUID UUID] UUIDString]]]];

    NSError *operationError = nil;
    BOOL succeeded = NO;
    @try {
        WCRReport(progress, @"复制微信副本（约 1–2 分钟）…");
        // XPlayer 的 vk_swiftshader_icd.json 用扩展属性承载签名元数据。
        // 关闭扩展属性复制会让视频组件和朋友圈辅助进程签名校验失败。
        if (!WCRRunProcess(@"/usr/bin/ditto",
                           @[@"--noclone",
                             @"--nopersistRootless",
                             @"--nohfsCompression",
                             sourceApp.path,
                             temporaryApp.path],
                           &operationError)) {
            @throw operationError;
        }

        NSString *resourcesPath = [temporaryApp.path stringByAppendingPathComponent:@"Contents/Resources"];
        NSURL *resourcesURL = [NSURL fileURLWithPath:resourcesPath isDirectory:YES];
        NSURL *installedDylib = [resourcesURL URLByAppendingPathComponent:@"WCRefineMac.dylib"];
        WCRReport(progress, @"写入 WCRefine 插件…");
        if (!WCRCopyItem([NSURL fileURLWithPath:dylibPath], installedDylib, &operationError)) {
            @throw operationError;
        }

        // 小宠物资源与 dylib 同目录发布。不能只复制 dylib：否则安装后
        // WKWebView 找不到 index.html/pet.js，右下角就只剩一片空白。
        NSURL *sourcePet = [[[NSURL fileURLWithPath:dylibPath] URLByDeletingLastPathComponent]
            URLByAppendingPathComponent:@"kimi-pet" isDirectory:YES];
        NSURL *installedPet = [resourcesURL URLByAppendingPathComponent:@"kimi-pet" isDirectory:YES];
        if (![fileManager fileExistsAtPath:sourcePet.path isDirectory:nil]) {
            @throw WCRInstallError([NSString stringWithFormat:
                @"找不到桌宠资源: %@（请用完整构建产物安装）", sourcePet.path]);
        }
        WCRReport(progress, @"写入桌宠资源…");
        if (!WCRCopyItem(sourcePet, installedPet, &operationError)) {
            @throw operationError;
        }

        WCRReport(progress, @"签名插件…");
        if (!WCRRunProcess(@"/usr/bin/codesign",
                           @[@"--force", @"--sign", @"-", @"--timestamp=none", installedDylib.path],
                           &operationError)) {
            @throw operationError;
        }

        WCRReport(progress, @"读取并保留微信原始权限…");
        NSString *binaryPath = [temporaryApp.path
            stringByAppendingPathComponent:@"Contents/MacOS/WeChat"];
        // 注入会改 Mach-O 头。先把沙盒权限读出来，避免签丢之后
        // crashpad 无法继承沙盒，安全模式就没有崩溃日志。
        NSDictionary<NSString *, id> *sourceEntitlements = nil;
        if (!WCRReadExecutableEntitlements(binaryPath, &sourceEntitlements, &operationError)) {
            @throw operationError;
        }
        if (![sourceEntitlements[@"com.apple.security.app-sandbox"] boolValue]) {
            @throw WCRInstallError(@"微信原始权限里没有沙盒，拒绝安装，以免安全模式写不出崩溃日志");
        }
        NSMutableDictionary<NSString *, id> *entitlements = [sourceEntitlements mutableCopy];
        entitlements[@"com.apple.security.cs.disable-library-validation"] = @YES;
        entitlements[@"com.apple.security.cs.allow-unsigned-executable-memory"] = @YES;

        WCRReport(progress, @"注入动态库加载命令…");
        if (!WCRInjectDylibLoadCommand(binaryPath, kWCRLoadPath, &operationError)) {
            @throw operationError;
        }

        NSString *infoPath = [temporaryApp.path stringByAppendingPathComponent:@"Contents/Info.plist"];
        NSMutableDictionary *info = [[NSMutableDictionary alloc] initWithContentsOfFile:infoPath];
        if (!info) {
            @throw WCRInstallError(@"无法读取副本 Info.plist");
        }
        if (bundleIdentifier.length > 0) {
            // 多开副本：改写 bundle id，让 macOS 分配独立沙盒容器，
            // 从根源上避免与原版微信/主副本争用同一数据目录。
            info[@"CFBundleIdentifier"] = bundleIdentifier;
            WCRReport(progress, [NSString stringWithFormat:
                @"多开标识: %@（独立数据目录，可与原版同时运行）", bundleIdentifier]);
        }
        info[@"CFBundleDisplayName"] = displayName.length > 0 ? displayName : @"WCRefine 微信";
        if (bundleIdentifier.length > 0) {
            info[@"CFBundleName"] = info[@"CFBundleDisplayName"];
        }
        if (![info writeToFile:infoPath atomically:YES]) {
            @throw WCRInstallError(@"无法写入副本 Info.plist");
        }

        NSData *entitlementData = [NSPropertyListSerialization
            dataWithPropertyList:entitlements
                          format:NSPropertyListXMLFormat_v1_0
                         options:0
                           error:&operationError];
        if (!entitlementData ||
            ![entitlementData writeToURL:temporaryEntitlements atomically:YES]) {
            @throw operationError ?: WCRInstallError(@"无法写入临时 entitlements");
        }

        WCRReport(progress, @"重签视频与朋友圈辅助组件…");
        for (NSString *relativePath in @[
                 @"Contents/MacOS/XPlayer.app",
                 @"Contents/MacOS/WeChatAppEx.app",
                 @"Contents/MacOS/WeChatHelper.app"]) {
            NSString *componentPath = [temporaryApp.path stringByAppendingPathComponent:relativePath];
            if (!WCRResignNestedApp(componentPath, progress, &operationError)) {
                @throw operationError;
            }
        }

        WCRReport(progress, @"重签名增强版微信…");
        if (!WCRRunProcess(@"/usr/bin/codesign",
                           @[@"--force", @"--sign", @"-",
                             @"--entitlements", temporaryEntitlements.path,
                             @"--timestamp=none", temporaryApp.path],
                           &operationError)) {
            @throw operationError;
        }

        for (NSString *relativePath in @[
                 @"Contents/MacOS/XPlayer.app",
                 @"Contents/MacOS/WeChatAppEx.app",
                 @"Contents/MacOS/WeChatHelper.app"]) {
            NSString *componentPath = [temporaryApp.path stringByAppendingPathComponent:relativePath];
            NSDictionary *componentInfo = [NSDictionary dictionaryWithContentsOfFile:
                [componentPath stringByAppendingPathComponent:@"Contents/Info.plist"]];
            NSString *componentExecutable = componentInfo[@"CFBundleExecutable"];
            NSString *componentBinary = [[componentPath stringByAppendingPathComponent:@"Contents/MacOS"]
                stringByAppendingPathComponent:componentExecutable ?: @""];
            NSDictionary<NSString *, id> *componentEntitlements = nil;
            if (!WCRReadExecutableEntitlements(componentBinary, &componentEntitlements, &operationError) ||
                ![componentEntitlements[@"com.apple.security.app-sandbox"] boolValue] ||
                ![componentEntitlements[@"com.apple.security.inherit"] boolValue]) {
                @throw WCRInstallError([NSString stringWithFormat:
                    @"辅助组件未保留沙盒继承权限: %@", relativePath]);
            }
        }

        WCRReport(progress, @"验证产物…");
        // 深度校验会同时检查 XPlayer 资源签名和辅助 App 的嵌套代码。
        if (!WCRRunProcess(@"/usr/bin/codesign",
                           @[@"--verify", @"--deep", @"--strict", temporaryApp.path],
                           &operationError)) {
            @throw operationError;
        }
        if (!WCRRunProcess(@"/usr/bin/codesign",
                           @[@"--verify", @"--strict", installedDylib.path],
                           &operationError)) {
            @throw operationError;
        }
        NSDictionary<NSString *, id> *signedEntitlements = nil;
        if (!WCRReadExecutableEntitlements(binaryPath, &signedEntitlements, &operationError)) {
            @throw operationError;
        }
        if (![signedEntitlements[@"com.apple.security.app-sandbox"] boolValue] ||
            ![signedEntitlements[@"com.apple.security.cs.disable-library-validation"] boolValue] ||
            ![signedEntitlements[@"com.apple.security.cs.allow-unsigned-executable-memory"] boolValue]) {
            @throw WCRInstallError(@"重签名后缺少沙盒或插件加载所需权限");
        }

        NSString *oldAppPath = nil;
        if ([fileManager fileExistsAtPath:destinationPath]) {
            oldAppPath = [parent.path stringByAppendingPathComponent:
                [NSString stringWithFormat:@".%@.old-%@", destinationApp.lastPathComponent,
                    [[NSUUID UUID] UUIDString]]];
            NSError *moveOldError = nil;
            if (![fileManager moveItemAtPath:destinationPath toPath:oldAppPath error:&moveOldError]) {
                @throw moveOldError;
            }
            WCRReport(progress, @"替换旧副本…");
        }

        if (![fileManager moveItemAtURL:temporaryApp
                                  toURL:destinationApp
                                  error:&operationError]) {
            if (oldAppPath) {
                [fileManager moveItemAtPath:oldAppPath toPath:destinationPath error:nil];
            }
            @throw operationError;
        }
        temporaryApp = nil;
        succeeded = YES;

        // 新副本已经落位，旧副本只作为原子替换时的临时回滚点，不再长期保留。
        if (oldAppPath) {
            NSError *cleanupError = nil;
            if (![fileManager removeItemAtPath:oldAppPath error:&cleanupError]) {
                WCRReport(progress, @"旧版本临时目录清理未完成，不影响当前副本");
            }
        }

        // 登记到 LaunchServices，让微信菜单里的「多开微信」能按 bundle id
        // 找到从未启动过的副本；登记失败不阻断安装。
        WCRReport(progress, @"登记 LaunchServices…");
        if (!WCRRunProcess(
                @"/System/Library/Frameworks/CoreServices.framework/Frameworks/"
                @"LaunchServices.framework/Support/lsregister",
                @[@"-f", destinationPath], &operationError)) {
            WCRReport(progress, @"LaunchServices 登记未完成（首次启动后自动补上），不影响使用。");
        }
        WCRReport(progress, [NSString stringWithFormat:@"完成: %@", destinationPath]);
    } @catch (NSError *caught) {
        operationError = caught;
        succeeded = NO;
    } @catch (id caught) {
        operationError = WCRInstallError([caught description]);
        succeeded = NO;
    } @finally {
        if (temporaryApp && [fileManager fileExistsAtPath:temporaryApp.path]) {
            [fileManager removeItemAtURL:temporaryApp error:nil];
        }
        [fileManager removeItemAtURL:temporaryEntitlements error:nil];
    }

    if (!succeeded && error) *error = operationError ?: WCRInstallError(@"安装失败");
    return succeeded;
}
