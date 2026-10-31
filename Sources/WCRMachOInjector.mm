#import "WCRMachOInjector.h"

#import <mach-o/fat.h>
#import <mach-o/loader.h>

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <unistd.h>
#include <vector>

namespace {

constexpr uint32_t kArm64CpuType = CPU_TYPE_ARM64;
constexpr uint32_t kMachoMagic64 = MH_MAGIC_64;
constexpr uint32_t kCSMagicEmbeddedSignature = 0xFADE0CC0;
constexpr uint32_t kCSMagicEmbeddedEntitlements = 0xFADE7171;
constexpr uint32_t kCSSlotEntitlements = 5;

NSError *WCRInjectorError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMac.MachO"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"未知注入错误"}];
}

uint32_t ReadBE32(const uint8_t *bytes, size_t offset, size_t size, bool *ok) {
    if (ok) *ok = true;
    if (offset > size || size - offset < sizeof(uint32_t)) {
        *ok = false;
        return 0;
    }
    uint32_t value = 0;
    memcpy(&value, bytes + offset, sizeof(value));
    return __builtin_bswap32(value);
}

uint32_t ReadLE32(const uint8_t *bytes, size_t offset) {
    uint32_t value = 0;
    memcpy(&value, bytes + offset, sizeof(value));
    return value;
}

uint64_t ReadLE64(const uint8_t *bytes, size_t offset) {
    uint64_t value = 0;
    memcpy(&value, bytes + offset, sizeof(value));
    return value;
}

void WriteLE32(uint8_t *bytes, size_t offset, uint32_t value) {
    memcpy(bytes + offset, &value, sizeof(value));
}

size_t Align8(size_t value) {
    return (value + 7) & ~static_cast<size_t>(7);
}

bool IsZero(const uint8_t *bytes, size_t length) {
    for (size_t i = 0; i < length; ++i) {
        if (bytes[i] != 0) return false;
    }
    return true;
}

bool IsDylibCommand(uint32_t command) {
    return command == LC_LOAD_DYLIB ||
           command == LC_LOAD_WEAK_DYLIB ||
           command == LC_REEXPORT_DYLIB ||
           command == LC_LOAD_UPWARD_DYLIB ||
           command == LC_LAZY_LOAD_DYLIB;
}

std::string CommandString(const uint8_t *slice, size_t commandOffset, uint32_t commandSize) {
    if (commandSize < 24) return {};
    uint32_t nameOffset = ReadLE32(slice, commandOffset + 8);
    if (nameOffset < 24 || nameOffset >= commandSize) return {};
    const char *name = reinterpret_cast<const char *>(slice + commandOffset + nameOffset);
    size_t maxLength = commandSize - nameOffset;
    size_t length = strnlen(name, maxLength);
    if (length == maxLength) return {};
    return std::string(name, length);
}

bool InjectSlice(uint8_t *slice,
                 size_t sliceSize,
                 NSString *loadPath,
                 bool *changed,
                 NSError **error) {
    if (sliceSize < sizeof(mach_header_64)) {
        if (error) *error = WCRInjectorError(@"Mach-O 头不完整");
        return NO;
    }
    if (ReadLE32(slice, 0) != kMachoMagic64 ||
        ReadLE32(slice, 4) != kArm64CpuType) {
        if (error) *error = WCRInjectorError(@"arm64 切片不是受支持的 MH_MAGIC_64");
        return NO;
    }

    uint32_t commandCount = ReadLE32(slice, 16);
    uint32_t commandBytes = ReadLE32(slice, 20);
    size_t headerEnd = sizeof(mach_header_64) + static_cast<size_t>(commandBytes);
    if (headerEnd > sliceSize) {
        if (error) *error = WCRInjectorError(@"Mach-O load commands 越界");
        return NO;
    }

    const std::string wanted = loadPath.UTF8String ?: "";
    size_t cursor = sizeof(mach_header_64);
    size_t firstSectionOffset = sliceSize;
    for (uint32_t index = 0; index < commandCount; ++index) {
        if (cursor > sliceSize || sliceSize - cursor < sizeof(load_command)) {
            if (error) *error = WCRInjectorError(@"Mach-O load command 损坏");
            return NO;
        }
        uint32_t command = ReadLE32(slice, cursor);
        uint32_t commandSize = ReadLE32(slice, cursor + 4);
        if (commandSize < sizeof(load_command) ||
            cursor > sliceSize || sliceSize - cursor < commandSize) {
            if (error) *error = WCRInjectorError(@"Mach-O load command 长度非法");
            return NO;
        }
        if (IsDylibCommand(command) && CommandString(slice, cursor, commandSize) == wanted) {
            *changed = false;
            return YES;
        }
        if (command == LC_SEGMENT_64) {
            if (commandSize < sizeof(segment_command_64)) {
                if (error) *error = WCRInjectorError(@"LC_SEGMENT_64 长度非法");
                return NO;
            }
            uint32_t sectionCount = ReadLE32(slice, cursor + 64);
            size_t sectionTableSize = static_cast<size_t>(sectionCount) * sizeof(section_64);
            if (sectionTableSize > commandSize - sizeof(segment_command_64)) {
                if (error) *error = WCRInjectorError(@"segment section table 越界");
                return NO;
            }
            for (uint32_t sectionIndex = 0; sectionIndex < sectionCount; ++sectionIndex) {
                size_t sectionOffset = cursor + sizeof(segment_command_64) +
                                       static_cast<size_t>(sectionIndex) * sizeof(section_64);
                uint64_t sectionSize = ReadLE64(slice, sectionOffset + 40);
                uint32_t fileOffset = ReadLE32(slice, sectionOffset + 48);
                if (sectionSize > 0 && fileOffset > 0) {
                    firstSectionOffset = std::min<size_t>(firstSectionOffset, fileOffset);
                }
            }
        }
        cursor += commandSize;
    }

    if (firstSectionOffset <= headerEnd || firstSectionOffset > sliceSize) {
        if (error) *error = WCRInjectorError(@"load commands 后没有可用填充空间");
        return NO;
    }

    NSData *pathData = [loadPath dataUsingEncoding:NSUTF8StringEncoding];
    if (!pathData || pathData.length == 0 || memchr(pathData.bytes, 0, pathData.length)) {
        if (error) *error = WCRInjectorError(@"动态库加载路径非法");
        return NO;
    }
    size_t commandSize = Align8(24 + pathData.length + 1);
    size_t padding = firstSectionOffset - headerEnd;
    if (commandSize > padding) {
        if (error) {
            *error = WCRInjectorError([NSString stringWithFormat:
                @"load command 填充不足（需要 %zu，可用 %zu）", commandSize, padding]);
        }
        return NO;
    }
    if (!IsZero(slice + headerEnd, commandSize)) {
        if (error) *error = WCRInjectorError(@"load command 填充区包含非零数据，拒绝覆盖");
        return NO;
    }

    std::vector<uint8_t> command(commandSize, 0);
    WriteLE32(command.data(), 0, LC_LOAD_DYLIB);
    WriteLE32(command.data(), 4, static_cast<uint32_t>(commandSize));
    WriteLE32(command.data(), 8, 24);
    WriteLE32(command.data(), 12, 2);
    memcpy(command.data() + 24, pathData.bytes, pathData.length);
    memcpy(slice + headerEnd, command.data(), command.size());

    WriteLE32(slice, 16, commandCount + 1);
    WriteLE32(slice, 20, commandBytes + static_cast<uint32_t>(commandSize));
    *changed = true;
    return YES;
}

BOOL WriteInPlace(NSString *path, NSData *data, NSError **error) {
    int descriptor = open(path.fileSystemRepresentation, O_WRONLY | O_TRUNC);
    if (descriptor < 0) {
        if (error) {
            *error = WCRInjectorError([NSString stringWithFormat:
                @"无法打开 %@: %s", path, strerror(errno)]);
        }
        return NO;
    }

    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    size_t remaining = data.length;
    size_t offset = 0;
    while (remaining > 0) {
        ssize_t written = write(descriptor, bytes + offset, remaining);
        if (written < 0) {
            if (errno == EINTR) continue;
            int savedErrno = errno;
            close(descriptor);
            if (error) {
                *error = WCRInjectorError([NSString stringWithFormat:
                    @"写入 Mach-O 失败: %s", strerror(savedErrno)]);
            }
            return NO;
        }
        offset += static_cast<size_t>(written);
        remaining -= static_cast<size_t>(written);
    }

    if (fsync(descriptor) != 0) {
        int savedErrno = errno;
        close(descriptor);
        if (error) {
            *error = WCRInjectorError([NSString stringWithFormat:
                @"同步 Mach-O 失败: %s", strerror(savedErrno)]);
        }
        return NO;
    }
    if (close(descriptor) != 0) {
        if (error) {
            *error = WCRInjectorError([NSString stringWithFormat:
                @"关闭 Mach-O 失败: %s", strerror(errno)]);
        }
        return NO;
    }
    return YES;
}


bool FindArm64SliceForReading(const uint8_t *bytes,
                              size_t size,
                              const uint8_t **slice,
                              size_t *sliceSize,
                              NSError **error) {
    if (size < 8) {
        if (error) *error = WCRInjectorError(@"Mach-O 文件过短");
        return false;
    }
    bool ok = true;
    uint32_t fatMagic = ReadBE32(bytes, 0, size, &ok);
    if (!ok) {
        if (error) *error = WCRInjectorError(@"Mach-O 头读取失败");
        return false;
    }
    if (fatMagic == FAT_MAGIC || fatMagic == FAT_MAGIC_64) {
        uint32_t count = ReadBE32(bytes, 4, size, &ok);
        if (!ok || count == 0 || count > 64) {
            if (error) *error = WCRInjectorError(@"Fat Mach-O 架构数量非法");
            return false;
        }
        size_t entrySize = fatMagic == FAT_MAGIC ? sizeof(fat_arch) : sizeof(fat_arch_64);
        size_t cursor = 8;
        for (uint32_t index = 0; index < count; ++index) {
            if (cursor > size || size - cursor < entrySize) {
                if (error) *error = WCRInjectorError(@"Fat Mach-O 架构表截断");
                return false;
            }
            uint32_t cpuType = ReadBE32(bytes, cursor, size, &ok);
            uint64_t offset = 0;
            uint64_t length = 0;
            if (fatMagic == FAT_MAGIC) {
                offset = ReadBE32(bytes, cursor + 8, size, &ok);
                length = ReadBE32(bytes, cursor + 12, size, &ok);
            } else {
                offset = (static_cast<uint64_t>(ReadBE32(bytes, cursor + 8, size, &ok)) << 32) |
                         ReadBE32(bytes, cursor + 12, size, &ok);
                length = (static_cast<uint64_t>(ReadBE32(bytes, cursor + 16, size, &ok)) << 32) |
                         ReadBE32(bytes, cursor + 20, size, &ok);
            }
            if (!ok || offset > size || length > size - offset) {
                if (error) *error = WCRInjectorError(@"Fat Mach-O 切片越界");
                return false;
            }
            if (cpuType == kArm64CpuType) {
                *slice = bytes + offset;
                *sliceSize = static_cast<size_t>(length);
                return true;
            }
            cursor += entrySize;
        }
        if (error) *error = WCRInjectorError(@"二进制不包含 arm64 切片");
        return false;
    }

    if (ReadLE32(bytes, 0) != kMachoMagic64 || ReadLE32(bytes, 4) != kArm64CpuType) {
        if (error) *error = WCRInjectorError(@"不是 arm64 MH_MAGIC_64");
        return false;
    }
    *slice = bytes;
    *sliceSize = size;
    return true;
}

NSDictionary<NSString *, id> *ReadEntitlementsFromCodeSignature(const uint8_t *slice,
                                                                 size_t sliceSize,
                                                                 NSError **error) {
    if (!slice || sliceSize < sizeof(mach_header_64)) {
        if (error) *error = WCRInjectorError(@"Mach-O 头不完整");
        return nil;
    }
    uint32_t commandCount = ReadLE32(slice, 16);
    uint32_t commandBytes = ReadLE32(slice, 20);
    size_t headerEnd = sizeof(mach_header_64) + static_cast<size_t>(commandBytes);
    if (headerEnd > sliceSize) {
        if (error) *error = WCRInjectorError(@"Mach-O load commands 越界");
        return nil;
    }

    uint32_t signatureOffset = 0;
    uint32_t signatureSize = 0;
    bool foundSignature = false;
    size_t cursor = sizeof(mach_header_64);
    for (uint32_t index = 0; index < commandCount; ++index) {
        if (cursor > sliceSize || sliceSize - cursor < sizeof(load_command)) {
            if (error) *error = WCRInjectorError(@"Mach-O load command 损坏");
            return nil;
        }
        uint32_t command = ReadLE32(slice, cursor);
        uint32_t commandSize = ReadLE32(slice, cursor + 4);
        if (commandSize < sizeof(load_command) ||
            cursor > sliceSize || sliceSize - cursor < commandSize) {
            if (error) *error = WCRInjectorError(@"Mach-O load command 长度非法");
            return nil;
        }
        if (command == LC_CODE_SIGNATURE) {
            if (commandSize < sizeof(linkedit_data_command)) {
                if (error) *error = WCRInjectorError(@"LC_CODE_SIGNATURE 长度非法");
                return nil;
            }
            signatureOffset = ReadLE32(slice, cursor + 8);
            signatureSize = ReadLE32(slice, cursor + 12);
            foundSignature = true;
            break;
        }
        cursor += commandSize;
    }

    if (!foundSignature) return @{};
    if (signatureOffset > sliceSize || signatureSize > sliceSize - signatureOffset ||
        signatureSize < 12) {
        if (error) *error = WCRInjectorError(@"代码签名数据越界");
        return nil;
    }

    const uint8_t *blob = slice + signatureOffset;
    bool ok = true;
    uint32_t magic = ReadBE32(blob, 0, signatureSize, &ok);
    uint32_t blobLength = ReadBE32(blob, 4, signatureSize, &ok);
    uint32_t count = ReadBE32(blob, 8, signatureSize, &ok);
    if (!ok || magic != kCSMagicEmbeddedSignature || blobLength < 12 ||
        blobLength > signatureSize || count > 1024 ||
        count > (blobLength - 12) / 8) {
        if (error) *error = WCRInjectorError(@"不支持的代码签名 SuperBlob");
        return nil;
    }
    const size_t blobSize = blobLength;

    for (uint32_t index = 0; index < count; ++index) {
        size_t entryOffset = 12 + static_cast<size_t>(index) * 8;
        uint32_t slotType = ReadBE32(blob, entryOffset, blobSize, &ok);
        uint32_t slotOffset = ReadBE32(blob, entryOffset + 4, blobSize, &ok);
        if (!ok || slotOffset > blobSize || blobSize - slotOffset < 8) {
            if (error) *error = WCRInjectorError(@"代码签名索引越界");
            return nil;
        }
        if (slotType != kCSSlotEntitlements) continue;

        uint32_t slotMagic = ReadBE32(blob, slotOffset, blobSize, &ok);
        uint32_t slotLength = ReadBE32(blob, slotOffset + 4, blobSize, &ok);
        if (!ok || slotMagic != kCSMagicEmbeddedEntitlements || slotLength < 8 ||
            slotLength > blobSize - slotOffset) {
            if (error) *error = WCRInjectorError(@"entitlements blob 损坏");
            return nil;
        }
        NSData *payload = [NSData dataWithBytes:blob + slotOffset + 8
                                         length:slotLength - 8];
        NSError *parseError = nil;
        id propertyList = [NSPropertyListSerialization propertyListWithData:payload
                                                                    options:0
                                                                     format:nil
                                                                      error:&parseError];
        if (![propertyList isKindOfClass:[NSDictionary class]]) {
            if (error) *error = parseError ?: WCRInjectorError(@"无法解析 entitlements");
            return nil;
        }
        return propertyList;
    }
    return @{};
}

}  // namespace

BOOL WCRInjectDylibLoadCommand(NSString *binaryPath,
                               NSString *loadPath,
                               NSError **error) {
    if (binaryPath.length == 0 || loadPath.length == 0) {
        if (error) *error = WCRInjectorError(@"缺少二进制或加载路径");
        return NO;
    }

    NSError *readError = nil;
    NSData *source = [NSData dataWithContentsOfFile:binaryPath
                                            options:NSDataReadingMappedIfSafe
                                              error:&readError];
    if (!source) {
        if (error) *error = readError ?: WCRInjectorError(@"无法读取 Mach-O");
        return NO;
    }
    if (source.length < 8) {
        if (error) *error = WCRInjectorError(@"Mach-O 文件过短");
        return NO;
    }

    NSMutableData *output = [source mutableCopy];
    uint8_t *bytes = static_cast<uint8_t *>(output.mutableBytes);
    bool isFat = false;
    bool changed = false;
    uint32_t fatMagic = ReadBE32(bytes, 0, source.length, &isFat);
    if (!isFat) {
        if (error) *error = WCRInjectorError(@"Fat Mach-O 头不完整");
        return NO;
    }

    uint32_t thinMagic = ReadLE32(bytes, 0);
    if (fatMagic == FAT_MAGIC || fatMagic == FAT_MAGIC_64) {
        bool ok = true;
        uint32_t count = ReadBE32(bytes, 4, source.length, &ok);
        if (!ok || count == 0 || count > 64) {
            if (error) *error = WCRInjectorError(@"Fat Mach-O 架构数量非法");
            return NO;
        }
        size_t entrySize = fatMagic == FAT_MAGIC ? sizeof(fat_arch) : sizeof(fat_arch_64);
        size_t cursor = 8;
        bool foundArm64 = false;
        for (uint32_t index = 0; index < count; ++index) {
            if (cursor > source.length || source.length - cursor < entrySize) {
                if (error) *error = WCRInjectorError(@"Fat Mach-O 架构表截断");
                return NO;
            }
            bool localOK = true;
            uint32_t cpuType = ReadBE32(bytes, cursor, source.length, &localOK);
            uint64_t sliceOffset = 0;
            uint64_t sliceSize = 0;
            if (fatMagic == FAT_MAGIC) {
                sliceOffset = ReadBE32(bytes, cursor + 8, source.length, &localOK);
                sliceSize = ReadBE32(bytes, cursor + 12, source.length, &localOK);
            } else {
                sliceOffset = (static_cast<uint64_t>(ReadBE32(bytes, cursor + 8, source.length, &localOK)) << 32) |
                              ReadBE32(bytes, cursor + 12, source.length, &localOK);
                sliceSize = (static_cast<uint64_t>(ReadBE32(bytes, cursor + 16, source.length, &localOK)) << 32) |
                            ReadBE32(bytes, cursor + 20, source.length, &localOK);
            }
            if (!localOK || sliceOffset > source.length || sliceSize > source.length - sliceOffset) {
                if (error) *error = WCRInjectorError(@"Fat Mach-O 切片越界");
                return NO;
            }
            cursor += entrySize;
            if (cpuType != kArm64CpuType) continue;
            foundArm64 = true;
            bool sliceChanged = false;
            if (!InjectSlice(bytes + sliceOffset,
                             static_cast<size_t>(sliceSize),
                             loadPath,
                             &sliceChanged,
                             error)) {
                return NO;
            }
            changed = changed || sliceChanged;
        }
        if (!foundArm64) {
            if (error) *error = WCRInjectorError(@"二进制不包含 arm64 切片");
            return NO;
        }
    } else if (thinMagic == kMachoMagic64) {
        bool sliceChanged = false;
        if (!InjectSlice(bytes, source.length, loadPath, &sliceChanged, error)) return NO;
        changed = sliceChanged;
    } else {
        if (error) *error = WCRInjectorError(@"不是受支持的 64 位 Mach-O");
        return NO;
    }

    if (!changed) return YES;
    return WriteInPlace(binaryPath, output, error);
}


BOOL WCRReadExecutableEntitlements(NSString *binaryPath,
                                   NSDictionary<NSString *, id> * _Nullable * _Nonnull entitlements,
                                   NSError **error) {
    if (binaryPath.length == 0) {
        if (error) *error = WCRInjectorError(@"缺少 Mach-O 路径");
        return NO;
    }
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:binaryPath
                                         options:NSDataReadingMappedIfSafe
                                           error:&readError];
    if (!data) {
        if (error) *error = readError ?: WCRInjectorError(@"无法读取 Mach-O");
        return NO;
    }
    const uint8_t *slice = nullptr;
    size_t sliceSize = 0;
    if (!FindArm64SliceForReading(static_cast<const uint8_t *>(data.bytes),
                                  data.length,
                                  &slice,
                                  &sliceSize,
                                  error)) {
        return NO;
    }
    NSDictionary *result = ReadEntitlementsFromCodeSignature(slice, sliceSize, error);
    if (!result) return NO;
    *entitlements = result;
    return YES;
}
