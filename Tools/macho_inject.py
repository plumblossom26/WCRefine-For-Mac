#!/usr/bin/env python3
"""Minimal, fail-closed LC_LOAD_DYLIB injector for arm64 Mach-O slices.

The installer only uses this on a freshly copied WeChat.app. The load command is
placed in existing zero padding after the current load commands, so section and
segment file offsets remain unchanged. Any unexpected layout aborts the install.
"""

from __future__ import annotations

import argparse
import plistlib
import struct
import sys
from pathlib import Path

LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0x0C
LC_CODE_SIGNATURE = 0x1D
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_TYPE_ARM64 = 0x0100000C
CSSLOT_ENTITLEMENTS = 5
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171


class MachOError(RuntimeError):
    pass


def align8(value: int) -> int:
    return (value + 7) & ~7


def parse_slices(data: bytes) -> list[tuple[int, int, int]]:
    if len(data) < 8:
        raise MachOError("binary is too short")
    magic_be = struct.unpack_from(">I", data, 0)[0]
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack_from(">I", data, 4)[0]
        if count == 0 or count > 64:
            raise MachOError("invalid fat architecture count")
        cursor = 8
        entry_size = 20 if magic_be == FAT_MAGIC else 32
        slices = []
        for _ in range(count):
            if cursor + entry_size > len(data):
                raise MachOError("truncated fat architecture table")
            if magic_be == FAT_MAGIC:
                cpu, _sub, offset, size, _align = struct.unpack_from(">iIIII", data, cursor)
            else:
                cpu, _sub, offset, size, _align, _reserved = struct.unpack_from(
                    ">iIQQII", data, cursor
                )
            if offset > len(data) or size > len(data) - offset:
                raise MachOError("fat slice is out of bounds")
            slices.append((cpu & 0xFFFFFFFF, offset, size))
            cursor += entry_size
        return slices

    magic_le = struct.unpack_from("<I", data, 0)[0]
    if magic_le != MH_MAGIC_64:
        raise MachOError("not a 64-bit Mach-O binary")
    cpu = struct.unpack_from("<I", data, 4)[0]
    return [(cpu, 0, len(data))]


def arm64_slices(data: bytes) -> list[tuple[int, int]]:
    found = [(offset, size) for cpu, offset, size in parse_slices(data) if cpu == CPU_TYPE_ARM64]
    if not found:
        raise MachOError("binary has no arm64 slice")
    return found


def parse_thin_header(slice_data: bytes) -> tuple[int, int, int]:
    if len(slice_data) < 32:
        raise MachOError("truncated Mach-O header")
    magic, cpu, _sub, _filetype, ncmds, sizeofcmds, _flags, _reserved = struct.unpack_from(
        "<IIIIIIII", slice_data, 0
    )
    if magic != MH_MAGIC_64:
        raise MachOError("arm64 slice is not little-endian MH_MAGIC_64")
    if cpu != CPU_TYPE_ARM64:
        raise MachOError("slice CPU type is not arm64")
    header_end = 32 + sizeofcmds
    if header_end > len(slice_data):
        raise MachOError("load commands exceed slice bounds")
    return ncmds, sizeofcmds, header_end


def iter_commands(slice_data: bytes):
    ncmds, _sizeofcmds, _header_end = parse_thin_header(slice_data)
    cursor = 32
    for index in range(ncmds):
        if cursor + 8 > len(slice_data):
            raise MachOError("truncated load command")
        cmd, cmdsize = struct.unpack_from("<II", slice_data, cursor)
        if cmdsize < 8 or cursor + cmdsize > len(slice_data):
            raise MachOError("invalid load command size")
        yield index, cursor, cmd, cmdsize
        cursor += cmdsize


def command_string(slice_data: bytes, command_offset: int) -> str | None:
    _cmd, cmdsize = struct.unpack_from("<II", slice_data, command_offset)
    if cmdsize < 24:
        return None
    name_offset = struct.unpack_from("<I", slice_data, command_offset + 8)[0]
    if name_offset < 24 or name_offset >= cmdsize:
        return None
    raw = slice_data[command_offset + name_offset : command_offset + cmdsize]
    return raw.split(b"\0", 1)[0].decode("utf-8", errors="replace")


def first_section_offset(slice_data: bytes) -> int:
    offsets = []
    for _index, command_offset, cmd, cmdsize in iter_commands(slice_data):
        if cmd != LC_SEGMENT_64:
            continue
        if cmdsize < 72:
            raise MachOError("truncated LC_SEGMENT_64")
        nsects = struct.unpack_from("<I", slice_data, command_offset + 64)[0]
        required = 72 + nsects * 80
        if required > cmdsize:
            raise MachOError("segment section table exceeds command size")
        for section_index in range(nsects):
            section_offset = command_offset + 72 + section_index * 80
            size = struct.unpack_from("<Q", slice_data, section_offset + 40)[0]
            file_offset = struct.unpack_from("<I", slice_data, section_offset + 48)[0]
            if size > 0 and file_offset > 0:
                offsets.append(file_offset)
    if not offsets:
        raise MachOError("could not find first section file offset")
    return min(offsets)


def has_load_path(slice_data: bytes, load_path: str) -> bool:
    for _index, command_offset, cmd, _cmdsize in iter_commands(slice_data):
        if cmd in (LC_LOAD_DYLIB, 0x18, 0x1F, 0x20, 0x8000001F):
            if command_string(slice_data, command_offset) == load_path:
                return True
    return False


def make_dylib_command(load_path: str) -> bytes:
    encoded = load_path.encode("utf-8")
    if not encoded or b"\0" in encoded:
        raise MachOError("invalid dylib load path")
    name_offset = 24
    cmdsize = align8(name_offset + len(encoded) + 1)
    command = struct.pack(
        "<IIIIII",
        LC_LOAD_DYLIB,
        cmdsize,
        name_offset,
        2,
        0,
        0,
    )
    name = encoded + b"\0"
    return command + name + b"\0" * (cmdsize - len(command) - len(name))


def inject_into_slice(slice_data: bytes, load_path: str) -> tuple[bytes, bool]:
    if has_load_path(slice_data, load_path):
        return slice_data, False

    ncmds, sizeofcmds, header_end = parse_thin_header(slice_data)
    first_content = first_section_offset(slice_data)
    if first_content <= header_end:
        raise MachOError("no padding after load commands")
    command = make_dylib_command(load_path)
    padding_size = first_content - header_end
    if len(command) > padding_size:
        raise MachOError(
            f"insufficient header padding ({padding_size} bytes, need {len(command)})"
        )

    if slice_data[header_end : header_end + len(command)] != b"\0" * len(command):
        raise MachOError("header padding is not zero; refusing to overwrite data")

    result = bytearray(slice_data)
    struct.pack_into("<I", result, 16, ncmds + 1)
    struct.pack_into("<I", result, 20, sizeofcmds + len(command))
    result[header_end : header_end + len(command)] = command
    return bytes(result), True


def inject_binary(path: Path, load_path: str) -> bool:
    data = path.read_bytes()
    slices = arm64_slices(data)
    output = bytearray(data)
    changed = False
    for offset, size in slices:
        original = bytes(data[offset : offset + size])
        patched, slice_changed = inject_into_slice(original, load_path)
        if slice_changed:
            output[offset : offset + size] = patched
            changed = True
    if changed:
        path.write_bytes(output)
    return changed


def entitlements_from_binary(path: Path) -> dict:
    data = path.read_bytes()
    slice_offset, slice_size = arm64_slices(data)[0]
    slice_data = data[slice_offset : slice_offset + slice_size]
    signature = None
    for _index, command_offset, cmd, cmdsize in iter_commands(slice_data):
        if cmd != LC_CODE_SIGNATURE:
            continue
        if cmdsize < 16:
            raise MachOError("invalid LC_CODE_SIGNATURE")
        signature = struct.unpack_from("<II", slice_data, command_offset + 8)
        break
    if signature is None:
        return {}
    data_offset, data_size = signature
    if data_offset > len(slice_data) or data_size > len(slice_data) - data_offset:
        raise MachOError("code signature is out of bounds")
    blob = slice_data[data_offset : data_offset + data_size]
    if len(blob) < 12:
        raise MachOError("truncated code signature")
    magic, blob_length, count = struct.unpack_from(">III", blob, 0)
    if (
        magic != CSMAGIC_EMBEDDED_SIGNATURE
        or blob_length < 12
        or blob_length > len(blob)
        or count > 1024
        or count > (blob_length - 12) // 8
    ):
        raise MachOError("unsupported code signature superblob")
    blob = blob[:blob_length]
    for index in range(count):
        entry_offset = 12 + index * 8
        if entry_offset + 8 > len(blob):
            raise MachOError("truncated signature index")
        slot_type, slot_offset = struct.unpack_from(">II", blob, entry_offset)
        if slot_type != CSSLOT_ENTITLEMENTS:
            continue
        if slot_offset > len(blob) or len(blob) - slot_offset < 8:
            raise MachOError("entitlement blob is out of bounds")
        slot_magic, slot_length = struct.unpack_from(">II", blob, slot_offset)
        if slot_magic != CSMAGIC_EMBEDDED_ENTITLEMENTS or slot_length < 8:
            raise MachOError("invalid entitlement blob")
        if slot_length > len(blob) - slot_offset:
            raise MachOError("truncated entitlement blob")
        payload = blob[slot_offset + 8 : slot_offset + slot_length]
        parsed = plistlib.loads(payload)
        if not isinstance(parsed, dict):
            raise MachOError("entitlements are not a dictionary")
        return parsed
    return {}


def export_entitlements(path: Path, output: Path) -> None:
    entitlements = entitlements_from_binary(path)
    entitlements["com.apple.security.cs.disable-library-validation"] = True
    entitlements["com.apple.security.cs.allow-unsigned-executable-memory"] = True
    with output.open("wb") as handle:
        plistlib.dump(entitlements, handle, sort_keys=False)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    inject_parser = subparsers.add_parser("inject")
    inject_parser.add_argument("--binary", required=True, type=Path)
    inject_parser.add_argument("--load-path", required=True)

    entitlements_parser = subparsers.add_parser("entitlements")
    entitlements_parser.add_argument("--binary", required=True, type=Path)
    entitlements_parser.add_argument("--output", required=True, type=Path)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--binary", required=True, type=Path)
    verify_parser.add_argument("--load-path", required=True)

    args = parser.parse_args()
    try:
        if args.command == "inject":
            changed = inject_binary(args.binary, args.load_path)
            print("injected" if changed else "already-present")
        elif args.command == "entitlements":
            export_entitlements(args.binary, args.output)
            print(f"entitlements={args.output}")
        else:
            data = args.binary.read_bytes()
            offset, size = arm64_slices(data)[0]
            if not has_load_path(data[offset : offset + size], args.load_path):
                raise MachOError("WCRefine load command is absent")
            print("load-command-present")
        return 0
    except (MachOError, OSError, ValueError, plistlib.InvalidFileException) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
