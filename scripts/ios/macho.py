"""Minimal Mach-O and static-archive reader for the iOS build validator.

The validator has to prove what CI produced without trusting xcodebuild's exit
status: the executable must be a device arm64 Mach-O built for iOS (not a
simulator or macOS slice), its deployment target must be at least iOS 18, and the
renderer archive must contain arm64 iOS objects with the Rust wm-shader and
C++ engine C ABI symbols. Xcode command-line tools are not assumed (the same checks
should be runnable on a machine without a full Xcode install), so this module
parses the file formats directly. It never executes anything from the binary.

Only 64-bit little-endian Mach-O is supported, which is all an arm64 iOS build
can produce.
"""
from __future__ import annotations

import hashlib
import struct
from dataclasses import dataclass, field
from pathlib import Path


class MachOError(ValueError):
    """The file is not a Mach-O or archive this module understands."""


MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF

MH_OBJECT = 0x1
MH_EXECUTE = 0x2
MH_DYLIB = 0x6

MH_PIE = 0x200000

CPU_TYPE_X86_64 = 0x01000007
CPU_TYPE_ARM64 = 0x0100000C
CPU_TYPE_ARM64_32 = 0x0200000C

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX = 0x24
LC_VERSION_MIN_IPHONEOS = 0x25
LC_VERSION_MIN_TVOS = 0x2F
LC_VERSION_MIN_WATCHOS = 0x30

PLATFORM_NAMES = {
    1: "macOS",
    2: "iOS",
    3: "tvOS",
    4: "watchOS",
    5: "bridgeOS",
    6: "Mac Catalyst",
    7: "iOS Simulator",
    8: "tvOS Simulator",
    9: "watchOS Simulator",
    10: "DriverKit",
    11: "visionOS",
    12: "visionOS Simulator",
}

_FILE_TYPES = {
    MH_OBJECT: "object",
    MH_EXECUTE: "execute",
    MH_DYLIB: "dylib",
    0x3: "fixed-vm-library",
    0x4: "core",
    0x5: "preload",
    0x7: "dynamic-linker",
    0x8: "bundle",
    0x9: "dylib-stub",
    0xB: "kext-bundle",
    0xC: "fileset",
}

_DYLIB_COMMANDS = {
    LC_LOAD_DYLIB,
    LC_LOAD_WEAK_DYLIB,
    LC_REEXPORT_DYLIB,
    LC_LAZY_LOAD_DYLIB,
    LC_LOAD_UPWARD_DYLIB,
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def arch_name(cpu_type: int, cpu_subtype: int) -> str:
    subtype = cpu_subtype & 0x00FFFFFF
    if cpu_type == CPU_TYPE_ARM64:
        return "arm64e" if subtype == 2 else "arm64"
    if cpu_type == CPU_TYPE_X86_64:
        return "x86_64"
    if cpu_type == CPU_TYPE_ARM64_32:
        return "arm64_32"
    return f"cpu-{cpu_type:#x}/{subtype:#x}"


def format_version(value: int) -> str:
    """Mach-O version field (xxxx.yy.zz nibbles) to ``major.minor[.patch]``."""
    major = (value >> 16) & 0xFFFF
    minor = (value >> 8) & 0xFF
    patch = value & 0xFF
    return f"{major}.{minor}" + (f".{patch}" if patch else "")


@dataclass
class MachOInfo:
    arch: str
    cpu_type: int
    cpu_subtype: int
    filetype: int
    platform: int | None
    platform_name: str | None
    minos: str | None
    sdk: str | None
    dylibs: list[str] = field(default_factory=list)
    has_code_signature: bool = False
    pie: bool = False
    offset: int = 0
    size: int = 0
    # Offsets are relative to this Mach-O's own start (fat slices are absolute in
    # the file but callers pass the slice base when reading).
    symtab: tuple[int, int, int, int] | None = None

    @property
    def filetype_name(self) -> str:
        return _FILE_TYPES.get(self.filetype, f"0x{self.filetype:x}")


def _read_cstring(data: bytes, offset: int, limit: int) -> str:
    if offset < 0 or offset >= limit:
        raise MachOError(f"string offset {offset} outside load command")
    end = data.find(b"\0", offset, limit)
    if end < 0:
        raise MachOError("unterminated load-command string")
    return data[offset:end].decode("utf-8", "replace")


def _parse_thin(data: bytes, base: int, size: int) -> MachOInfo:
    if size < 32 or base + size > len(data):
        raise MachOError("truncated Mach-O header")
    magic = struct.unpack_from("<I", data, base)[0]
    if magic == MH_CIGAM_64:
        raise MachOError("big-endian Mach-O is not an iOS arm64 build")
    if magic != MH_MAGIC_64:
        raise MachOError(f"not a 64-bit Mach-O (magic {magic:#x})")

    cpu_type, cpu_subtype, filetype, ncmds, sizeofcmds, flags, _reserved = struct.unpack_from(
        "<iiIIIII", data, base + 4
    )
    if ncmds > 100_000:
        raise MachOError(f"implausible load-command count {ncmds}")
    if 32 + sizeofcmds > size:
        raise MachOError("load commands exceed the Mach-O slice")

    platform: int | None = None
    platform_name: str | None = None
    minos: str | None = None
    sdk: str | None = None
    dylibs: list[str] = []
    has_code_signature = False
    symtab: tuple[int, int, int, int] | None = None

    position = base + 32
    end = position + sizeofcmds
    for _ in range(ncmds):
        if position + 8 > end:
            raise MachOError("load command runs past sizeofcmds")
        command, command_size = struct.unpack_from("<II", data, position)
        if command_size < 8 or position + command_size > end:
            raise MachOError(f"invalid load command size {command_size}")
        if command == LC_BUILD_VERSION:
            if command_size < 24:
                raise MachOError("truncated LC_BUILD_VERSION")
            platform, minos_value, sdk_value = struct.unpack_from("<III", data, position + 8)
            minos = format_version(minos_value)
            sdk = format_version(sdk_value)
            platform_name = PLATFORM_NAMES.get(platform, f"platform-{platform}")
        elif command == LC_VERSION_MIN_MACOSX:
            platform, platform_name = 1, PLATFORM_NAMES[1]
            (minos_value,) = struct.unpack_from("<I", data, position + 8)
            minos = format_version(minos_value)
        elif command == LC_VERSION_MIN_IPHONEOS:
            platform, platform_name = 2, PLATFORM_NAMES[2]
            (minos_value,) = struct.unpack_from("<I", data, position + 8)
            minos = format_version(minos_value)
        elif command == LC_VERSION_MIN_TVOS:
            platform, platform_name = 3, PLATFORM_NAMES[3]
        elif command == LC_VERSION_MIN_WATCHOS:
            platform, platform_name = 4, PLATFORM_NAMES[4]
        elif command in _DYLIB_COMMANDS:
            if command_size < 24:
                raise MachOError("truncated dylib load command")
            (name_offset,) = struct.unpack_from("<I", data, position + 8)
            name = _read_cstring(data, position + name_offset, position + command_size)
            if name not in dylibs:
                dylibs.append(name)
        elif command == LC_CODE_SIGNATURE:
            has_code_signature = True
        elif command == LC_SYMTAB:
            if command_size < 24:
                raise MachOError("truncated LC_SYMTAB")
            symtab = struct.unpack_from("<IIII", data, position + 8)
        position += command_size

    return MachOInfo(
        arch=arch_name(cpu_type, cpu_subtype),
        cpu_type=cpu_type,
        cpu_subtype=cpu_subtype,
        filetype=filetype,
        platform=platform,
        platform_name=platform_name,
        minos=minos,
        sdk=sdk,
        dylibs=dylibs,
        has_code_signature=has_code_signature,
        pie=bool(flags & MH_PIE),
        offset=base,
        size=size,
        symtab=symtab,
    )


def parse_macho(path: Path) -> list[MachOInfo]:
    """All thin slices of a Mach-O file, in file order."""
    return parse_macho_bytes(Path(path).read_bytes())


def parse_macho_bytes(data: bytes) -> list[MachOInfo]:
    """All thin slices of Mach-O bytes (an IPA member is not a file on disk)."""
    if len(data) < 4:
        raise MachOError("file is too short to be Mach-O")
    big_magic = struct.unpack_from(">I", data, 0)[0]
    if big_magic in (FAT_MAGIC, FAT_MAGIC_64):
        return _parse_fat(data)
    return [_parse_thin(data, 0, len(data))]


def _parse_fat(data: bytes) -> list[MachOInfo]:
    magic = struct.unpack_from(">I", data, 0)[0]
    (count,) = struct.unpack_from(">I", data, 4)
    if count == 0 or count > 64:
        raise MachOError(f"implausible fat Mach-O slice count {count}")
    entry_size = 32 if magic == FAT_MAGIC_64 else 20
    table = 8 + count * entry_size
    if table > len(data):
        raise MachOError("fat Mach-O header exceeds the file")
    slices: list[MachOInfo] = []
    for index in range(count):
        start = 8 + index * entry_size
        if magic == FAT_MAGIC_64:
            _cpu, _sub, offset, size, _align, _reserved = struct.unpack_from(">iiQQII", data, start)
        else:
            _cpu, _sub, offset, size, _align = struct.unpack_from(">iiIII", data, start)
        if offset + size > len(data):
            raise MachOError("fat Mach-O slice exceeds the file")
        slices.append(_parse_thin(data, offset, size))
    return slices


def collect_symbols(
    data: bytes,
    info: MachOInfo,
    wanted: dict[str, list[str]],
    max_symbols: int = 200_000,
) -> dict[str, list[str]]:
    """Map each wanted key to the symbols found that contain one of its needles.

    ``info.symtab`` offsets are relative to the start of the slice, whose file
    offset is ``info.offset``.
    """
    found: dict[str, list[str]] = {key: [] for key in wanted}
    if info.symtab is None:
        return found
    symoff, nsyms, stroff, strsize = info.symtab
    if nsyms > max_symbols:
        raise MachOError(f"implausible symbol count {nsyms}")
    string_base = info.offset + stroff
    string_end = string_base + strsize
    if string_end > len(data):
        raise MachOError("symbol string table exceeds the file")
    for index in range(nsyms):
        entry = info.offset + symoff + index * 16
        if entry + 16 > len(data):
            raise MachOError("symbol table exceeds the file")
        (string_index,) = struct.unpack_from("<I", data, entry)
        if string_index == 0 or string_index >= strsize:
            continue
        start = string_base + string_index
        stop = data.find(b"\0", start, string_end)
        if stop < 0:
            continue
        name = data[start:stop].decode("utf-8", "replace")
        lowered = name.lower()
        for key, needles in wanted.items():
            if len(found[key]) < 3 and any(needle in lowered for needle in needles):
                if name not in found[key]:
                    found[key].append(name)
    return found


@dataclass
class ArchiveInfo:
    path: Path
    sha256: str
    size: int
    members: int
    objects: int
    archs: dict[str, int]
    object_platforms: dict[int, int]
    symbols: dict[str, list[str]]
    has_code_signature: bool

    @property
    def macos_objects(self) -> int:
        return self.object_platforms.get(1, 0)

    @property
    def simulator_objects(self) -> int:
        return self.object_platforms.get(7, 0)

    @property
    def ios_objects(self) -> int:
        return self.object_platforms.get(2, 0)

    @property
    def unknown_platform_objects(self) -> int:
        return self.object_platforms.get(0, 0)


# Mach-O archives are Ar with a ``!<arch>\\n`` magic. macOS's ar/libtool uses
# BSD long names (``#1/<len>``); GNU ar uses a ``//`` string table. A combined
# renderer archive should come from libtool, but both forms are read.
_AR_MAGIC = b"!<arch>\n"
_AR_HEADER = 60


def _ar_name(field: bytes) -> str:
    return field.decode("ascii", "replace").rstrip()


def inspect_archive(path: Path, wanted_symbols: dict[str, list[str]] | None = None) -> ArchiveInfo:
    path = Path(path)
    data = path.read_bytes()
    if len(data) < 8 or not data.startswith(_AR_MAGIC):
        raise MachOError("not a static archive (missing !<arch> magic)")

    wanted = wanted_symbols or {}
    symbols: dict[str, list[str]] = {key: [] for key in wanted}
    archs: dict[str, int] = {}
    platforms: dict[int, int] = {}
    members = 0
    objects = 0
    code_signature = False
    gnu_names = b""
    position = 8
    while position < len(data):
        if position + _AR_HEADER > len(data):
            raise MachOError("truncated archive member header")
        header = data[position : position + _AR_HEADER]
        if header[58:60] != b"`\n":
            raise MachOError(f"bad archive member header magic at offset {position}")
        raw_name = _ar_name(header[0:16])
        try:
            size = int(header[48:58].decode("ascii").strip())
        except ValueError as error:
            raise MachOError(f"bad archive member size at offset {position}") from error
        position += _AR_HEADER
        if size < 0 or position + size > len(data):
            raise MachOError("archive member extends past the end of the file")
        payload_start = position
        payload_size = size
        name = raw_name
        if raw_name.startswith("#1/"):
            try:
                name_length = int(raw_name[3:])
            except ValueError as error:
                raise MachOError("bad BSD archive name length") from error
            if name_length > payload_size:
                raise MachOError("BSD archive name longer than its member")
            name = data[payload_start : payload_start + name_length].rstrip(b"\0").decode(
                "utf-8", "replace"
            )
            payload_start += name_length
            payload_size -= name_length
        elif raw_name == "//":
            gnu_names = data[payload_start : payload_start + payload_size]
            name = "//"
        elif raw_name.startswith("/") and raw_name[1:].isdigit():
            offset = int(raw_name[1:])
            end = gnu_names.find(b"/\n", offset)
            if end < 0:
                raise MachOError("unresolved GNU archive name")
            name = gnu_names[offset:end].decode("utf-8", "replace")

        if name in ("/", "//", "/SYM64/", "__.SYMDEF", "__.SYMDEF SORTED"):
            position += size + (size & 1)
            continue

        payload = data[payload_start : payload_start + payload_size]
        if len(payload) >= 4:
            magic = struct.unpack_from("<I", payload, 0)[0]
            if magic in (MH_MAGIC_64, MH_CIGAM_64):
                info = _parse_thin(payload, 0, len(payload))
                if info.filetype == MH_OBJECT:
                    objects += 1
                members += 1
                archs[info.arch] = archs.get(info.arch, 0) + 1
                platform_key = info.platform if info.platform is not None else 0
                platforms[platform_key] = platforms.get(platform_key, 0) + 1
                if info.has_code_signature:
                    code_signature = True
                if wanted and any(not values for values in symbols.values()):
                    found = collect_symbols(payload, info, wanted)
                    for key, values in found.items():
                        for value in values:
                            if len(symbols[key]) < 3 and value not in symbols[key]:
                                symbols[key].append(value)
        position += size + (size & 1)

    return ArchiveInfo(
        path=path,
        sha256=sha256_file(path),
        size=len(data),
        members=members,
        objects=objects,
        archs=archs,
        object_platforms=platforms,
        symbols=symbols,
        has_code_signature=code_signature,
    )
