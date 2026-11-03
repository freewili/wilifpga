#!/usr/bin/env python3
"""The `.fwfpga` container: a bitstream never travels without its IO metadata.

    python tools/fwfpga_format.py inspect file.fwfpga      # header + direction summary

Layout (docs/fwfpga-format.md), little-endian, 256-byte header:

    off  size  field
    0    8     magic            "FW2FPGA\\0"
    8    1     format_version   1
    9    1     contract_version 1 (ID block contract the design was built to)
    10   2     header_len       256
    12   4     manifest_len     JSON blob length (may be 0)
    16   4     bitstream_len
    20   4     bitstream_crc32  zlib CRC-32 of the bitstream
    24   32    bitstream_sha256
    56   32    name             ASCII, NUL padded, <=31 chars
    88   128   description      ASCII, NUL padded, <=127 chars
    216  2     design_id        u16; 0xFFFF = stock gateware (no ID block expected)
    218  2     design_version   u16, 000..999
    220  1     capabilities     IO_BUFFER=1 STREAM=2 PSRAM_SWAP=4 CM0=8 I2C_SLAVE=16
    221  1     clock_code       0=31.25 MHz 1=12.5 2=25 3=48
    222  4     io_profile       10 x 3-bit, packed (tools/profile.py)
    226  1     kind             0 = user design, 1 = stock passthrough
    227  25    reserved         zero
    252  4     header_crc32     zlib CRC-32 over bytes 0..251
    256  ...   manifest JSON (host only)
    ...  ...   iCE40 bitstream (0x7E 0xAA 0x99 0x7E preamble within the first 64 bytes)

This file is the single source of the layout: gen_fwfpga_format_h.py renders
the C header for the firmware from FIELDS below.
"""
import hashlib
import json
import struct
import sys
import zlib
from dataclasses import dataclass, asdict

MAGIC = b"FW2FPGA\0"
FORMAT_VERSION = 1
CONTRACT_VERSION = 1
HEADER_LEN = 256
HEADER_CRC_SPAN = 252
NAME_LEN = 32
DESCRIPTION_LEN = 128
RESERVED_LEN = 25
KIND_USER = 0
KIND_STOCK = 1
STOCK_DESIGN_ID = 0xFFFF
ICE40_PREAMBLE = bytes([0x7E, 0xAA, 0x99, 0x7E])
PREAMBLE_WINDOW = 64
# Size bounds applied by check_container / pack_fwfpga (not by unpack): an
# UP5K bitstream is ~104 KB; 1 MB leaves room for any iCE40 image.
BITSTREAM_MIN = 100 * 1024
BITSTREAM_MAX = 1024 * 1024

# (name, offset, size, struct code, C type). The struct string is derived from
# this table, so the table is the layout.
FIELDS = (
    ("magic", 0, 8, "8s", "uint8_t[8]"),
    ("format_version", 8, 1, "B", "uint8_t"),
    ("contract_version", 9, 1, "B", "uint8_t"),
    ("header_len", 10, 2, "H", "uint16_t"),
    ("manifest_len", 12, 4, "I", "uint32_t"),
    ("bitstream_len", 16, 4, "I", "uint32_t"),
    ("bitstream_crc32", 20, 4, "I", "uint32_t"),
    ("bitstream_sha256", 24, 32, "32s", "uint8_t[32]"),
    ("name", 56, 32, "32s", "char[32]"),
    ("description", 88, 128, "128s", "char[128]"),
    ("design_id", 216, 2, "H", "uint16_t"),
    ("design_version", 218, 2, "H", "uint16_t"),
    ("capabilities", 220, 1, "B", "uint8_t"),
    ("clock_code", 221, 1, "B", "uint8_t"),
    ("io_profile", 222, 4, "I", "uint32_t"),
    ("kind", 226, 1, "B", "uint8_t"),
    ("reserved", 227, 25, "25s", "uint8_t[25]"),
    ("header_crc32", 252, 4, "I", "uint32_t"),
)
STRUCT_FMT = "<" + "".join(f[3] for f in FIELDS)
assert struct.calcsize(STRUCT_FMT) == HEADER_LEN
for _i, _f in enumerate(FIELDS):
    assert _f[1] == struct.calcsize("<" + "".join(x[3] for x in FIELDS[:_i])), _f
    assert _f[2] == struct.calcsize("<" + _f[3]), _f


class FormatError(ValueError):
    pass


def crc32(data, value=0):
    return zlib.crc32(data, value) & 0xFFFFFFFF


def sha256(data):
    return hashlib.sha256(data).digest()


def _cstr(raw):
    return raw.split(b"\0", 1)[0].decode("ascii", "replace")


def _pad(text, size, what):
    if any(ord(c) < 0x20 or ord(c) > 0x7E for c in text):
        raise FormatError(f"{what} must be printable ASCII")
    raw = text.encode("ascii")
    if len(raw) > size - 1:
        raise FormatError(f"{what} is {len(raw)} bytes; max {size - 1}")
    return raw.ljust(size, b"\0")


@dataclass
class Header:
    name: str
    description: str
    design_id: int
    design_version: int
    capabilities: int
    clock_code: int
    io_profile: int
    kind: int
    manifest_len: int = 0
    bitstream_len: int = 0
    bitstream_crc32: int = 0
    bitstream_sha256: bytes = b"\0" * 32
    format_version: int = FORMAT_VERSION
    contract_version: int = CONTRACT_VERSION
    header_len: int = HEADER_LEN
    reserved: bytes = b"\0" * RESERVED_LEN
    header_crc32: int = 0      # filled by to_bytes()

    def to_bytes(self):
        """Serialise, computing header_crc32. Raises FormatError on out-of-range fields."""
        self._check_ranges()
        body = struct.pack(
            STRUCT_FMT[:-1],  # everything but the trailing crc
            MAGIC, self.format_version, self.contract_version, self.header_len,
            self.manifest_len, self.bitstream_len, self.bitstream_crc32, self.bitstream_sha256,
            _pad(self.name, NAME_LEN, "name"), _pad(self.description, DESCRIPTION_LEN, "description"),
            self.design_id, self.design_version, self.capabilities, self.clock_code,
            self.io_profile, self.kind, self.reserved)
        assert len(body) == HEADER_CRC_SPAN
        self.header_crc32 = crc32(body)
        return body + struct.pack("<I", self.header_crc32)

    def _check_ranges(self):
        for field_name, bits in (("design_id", 16), ("design_version", 16), ("capabilities", 8),
                                 ("clock_code", 8), ("io_profile", 32), ("kind", 8),
                                 ("manifest_len", 32), ("bitstream_len", 32), ("bitstream_crc32", 32),
                                 ("format_version", 8), ("contract_version", 8), ("header_len", 16)):
            v = getattr(self, field_name)
            if not isinstance(v, int) or not 0 <= v < (1 << bits):
                raise FormatError(f"{field_name}={v!r} does not fit {bits} bits")
        if len(self.bitstream_sha256) != 32:
            raise FormatError("bitstream_sha256 must be 32 bytes")
        if len(self.reserved) != RESERVED_LEN:
            raise FormatError(f"reserved must be {RESERVED_LEN} bytes")

    @classmethod
    def from_bytes(cls, raw, check=True):
        """Parse 256 bytes. With check=True, rejects bad magic, unknown format, bad CRC."""
        if len(raw) < HEADER_LEN:
            raise FormatError(f"header needs {HEADER_LEN} bytes, got {len(raw)}")
        raw = bytes(raw[:HEADER_LEN])
        (magic, format_version, contract_version, header_len, manifest_len, bitstream_len,
         bitstream_crc32, bitstream_sha256, name, description, design_id, design_version,
         capabilities, clock_code, io_profile, kind, reserved, header_crc32) = struct.unpack(STRUCT_FMT, raw)
        if check:
            if magic != MAGIC:
                raise FormatError(f"bad magic {magic!r}; not a .fwfpga container")
            if format_version != FORMAT_VERSION:
                raise FormatError(f"unknown format_version {format_version} (this tool knows {FORMAT_VERSION})")
            computed = crc32(raw[:HEADER_CRC_SPAN])
            if header_crc32 != computed:
                raise FormatError(f"header CRC32 0x{header_crc32:08X} != computed 0x{computed:08X}")
            if header_len != HEADER_LEN:
                raise FormatError(f"header_len {header_len} != {HEADER_LEN}")
        return cls(name=_cstr(name), description=_cstr(description), design_id=design_id,
                   design_version=design_version, capabilities=capabilities, clock_code=clock_code,
                   io_profile=io_profile, kind=kind, manifest_len=manifest_len, bitstream_len=bitstream_len,
                   bitstream_crc32=bitstream_crc32, bitstream_sha256=bitstream_sha256,
                   format_version=format_version, contract_version=contract_version, header_len=header_len,
                   reserved=reserved, header_crc32=header_crc32)

    def as_dict(self):
        d = asdict(self)
        d["bitstream_sha256"] = self.bitstream_sha256.hex()
        d["reserved"] = self.reserved.hex()
        return d


def pack(header, manifest, bitstream):
    """Header (lengths/CRCs filled here) + manifest (dict, str, bytes or None) + bitstream -> bytes."""
    if manifest is None:
        mbytes = b""
    elif isinstance(manifest, (dict, list)):
        mbytes = json.dumps(manifest, indent=1, sort_keys=True).encode("utf-8")
    elif isinstance(manifest, str):
        mbytes = manifest.encode("utf-8")
    else:
        mbytes = bytes(manifest)
    bitstream = bytes(bitstream)
    header.manifest_len = len(mbytes)
    header.bitstream_len = len(bitstream)
    header.bitstream_crc32 = crc32(bitstream)
    header.bitstream_sha256 = sha256(bitstream)
    return header.to_bytes() + mbytes + bitstream


def unpack(blob):
    """bytes -> (Header, manifest bytes, bitstream bytes). Verifies lengths, CRCs and SHA-256."""
    header = Header.from_bytes(blob)
    expected = HEADER_LEN + header.manifest_len + header.bitstream_len
    if len(blob) != expected:
        raise FormatError(f"file is {len(blob)} bytes; header says {expected} "
                          f"(256 + manifest {header.manifest_len} + bitstream {header.bitstream_len})")
    manifest = bytes(blob[HEADER_LEN:HEADER_LEN + header.manifest_len])
    bitstream = bytes(blob[HEADER_LEN + header.manifest_len:])
    c = crc32(bitstream)
    if c != header.bitstream_crc32:
        raise FormatError(f"bitstream CRC32 0x{header.bitstream_crc32:08X} != computed 0x{c:08X}")
    s = sha256(bitstream)
    if s != header.bitstream_sha256:
        raise FormatError(f"bitstream SHA-256 {header.bitstream_sha256.hex()} != computed {s.hex()}")
    return header, manifest, bitstream


def has_preamble(bitstream, window=PREAMBLE_WINDOW):
    return bytes(bitstream[:window]).find(ICE40_PREAMBLE) >= 0


def validate(blob, size_bounds=True, min_size=BITSTREAM_MIN, max_size=BITSTREAM_MAX):
    """Every check of contract rule 8 that needs no design.toml. Returns (Header, manifest, bitstream)
    or raises FormatError with the first failure."""
    import profile as iop
    header, manifest, bitstream = unpack(blob)
    if header.contract_version != CONTRACT_VERSION:
        raise FormatError(f"contract_version {header.contract_version} != {CONTRACT_VERSION}")
    if header.kind not in (KIND_USER, KIND_STOCK):
        raise FormatError(f"kind {header.kind} is not 0 (user) or 1 (stock)")
    if header.kind == KIND_STOCK and header.design_id != STOCK_DESIGN_ID:
        raise FormatError(f"stock container must have design_id 0xFFFF, has 0x{header.design_id:04X}")
    if header.kind == KIND_USER and header.design_id == STOCK_DESIGN_ID:
        raise FormatError("design_id 0xFFFF is reserved for kind = stock")
    if header.design_version > 999:
        raise FormatError(f"design_version {header.design_version} > 999")
    if header.reserved != b"\0" * RESERVED_LEN:
        raise FormatError("reserved bytes are not zero")
    if not header.name:
        raise FormatError("name is empty")
    if not header.description:
        raise FormatError("description is empty")
    try:
        iop.unpack(header.io_profile)
    except iop.ProfileError as exc:
        raise FormatError(str(exc)) from exc
    if header.capabilities & ~0x3F:   # IO_BUFFER STREAM PSRAM_SWAP CM0 I2C_SLAVE PIO_LINK
        raise FormatError(f"capabilities 0x{header.capabilities:02X} has unknown bits")
    if header.clock_code > 3:
        raise FormatError(f"clock_code {header.clock_code} is unknown")
    if not has_preamble(bitstream):
        raise FormatError("bitstream has no iCE40 preamble 7E AA 99 7E in its first 64 bytes")
    if size_bounds and not min_size <= len(bitstream) <= max_size:
        raise FormatError(f"bitstream is {len(bitstream)} bytes; expected {min_size}..{max_size}")
    if manifest:
        try:
            json.loads(manifest.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise FormatError(f"manifest is not JSON: {exc}") from exc
    return header, manifest, bitstream


def describe(header):
    import profile as iop
    try:
        prof = iop.unpack(header.io_profile)
        prof_text = iop.summary(prof)
    except iop.ProfileError as exc:
        prof_text = f"(invalid: {exc})"
    kind = {KIND_USER: "user", KIND_STOCK: "stock"}.get(header.kind, f"unknown({header.kind})")
    lines = [
        f"name:           {header.name}",
        f"description:    {header.description}",
        f"version:        {header.design_version:03d}",
        f"design_id:      {header.design_id} (0x{header.design_id:04X})",
        f"kind:           {kind}",
        f"capabilities:   0x{header.capabilities:02X}",
        f"clock_code:     {header.clock_code}",
        f"io_profile:     0x{header.io_profile:08X}  {prof_text}",
        f"format/contract {header.format_version}/{header.contract_version}",
        f"manifest_len:   {header.manifest_len}",
        f"bitstream_len:  {header.bitstream_len}  crc32 0x{header.bitstream_crc32:08X}",
        f"bitstream_sha256: {header.bitstream_sha256.hex()}",
        f"header_crc32:   0x{header.header_crc32:08X}",
    ]
    return "\n".join(lines)


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("inspect")
    s.add_argument("file")
    s.add_argument("--manifest", action="store_true", help="also print the manifest JSON")
    a = p.parse_args(argv)
    blob = open(a.file, "rb").read()
    try:
        header, manifest, _ = validate(blob, size_bounds=False)
    except FormatError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(describe(header))
    if a.manifest and manifest:
        print(manifest.decode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
