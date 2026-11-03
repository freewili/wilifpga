import hashlib
import json
import struct
import zlib

import pytest

import fwfpga_format as ff
import profile as iop
from conftest import fake_bitstream


def header(**kw):
    base = dict(name="hello_blink", description="Blink GPIO26", design_id=1, design_version=1,
                capabilities=3, clock_code=0, io_profile=iop.pack(dict(iop.STOCK_PROFILE, gpio26="FPGA_OUT")),
                kind=ff.KIND_USER)
    base.update(kw)
    return ff.Header(**base)


def test_layout_table_matches_spec():
    offsets = {f[0]: (f[1], f[2]) for f in ff.FIELDS}
    assert offsets == {
        "magic": (0, 8), "format_version": (8, 1), "contract_version": (9, 1), "header_len": (10, 2),
        "manifest_len": (12, 4), "bitstream_len": (16, 4), "bitstream_crc32": (20, 4),
        "bitstream_sha256": (24, 32), "name": (56, 32), "description": (88, 128), "design_id": (216, 2),
        "design_version": (218, 2), "capabilities": (220, 1), "clock_code": (221, 1), "io_profile": (222, 4),
        "kind": (226, 1), "reserved": (227, 25), "header_crc32": (252, 4),
    }
    assert ff.HEADER_LEN == 256 and ff.MAGIC == b"FW2FPGA\0" and len(ff.MAGIC) == 8


def test_pack_bytes_exactly(bitstream):
    manifest = {"a": 1}
    blob = ff.pack(header(), manifest, bitstream)
    mbytes = json.dumps(manifest, indent=1, sort_keys=True).encode()
    assert blob[:8] == b"FW2FPGA\0"
    assert blob[8] == 1 and blob[9] == 1
    assert struct.unpack_from("<H", blob, 10)[0] == 256
    assert struct.unpack_from("<I", blob, 12)[0] == len(mbytes)
    assert struct.unpack_from("<I", blob, 16)[0] == len(bitstream)
    assert struct.unpack_from("<I", blob, 20)[0] == zlib.crc32(bitstream)
    assert blob[24:56] == hashlib.sha256(bitstream).digest()
    assert blob[56:88] == b"hello_blink".ljust(32, b"\0")
    assert blob[88:216] == b"Blink GPIO26".ljust(128, b"\0")
    assert struct.unpack_from("<H", blob, 216)[0] == 1
    assert struct.unpack_from("<H", blob, 218)[0] == 1
    assert blob[220] == 3 and blob[221] == 0
    assert struct.unpack_from("<I", blob, 222)[0] == iop.pack(dict(iop.STOCK_PROFILE, gpio26="FPGA_OUT"))
    assert blob[226] == 0
    assert blob[227:252] == b"\0" * 25
    assert struct.unpack_from("<I", blob, 252)[0] == zlib.crc32(blob[:252])
    assert blob[256:256 + len(mbytes)] == mbytes
    assert blob[256 + len(mbytes):] == bitstream


def test_round_trip(bitstream):
    h = header(description="d" * 127, name="n" * 31, design_version=999, capabilities=0x1F, clock_code=3)
    blob = ff.pack(h, {"k": "v"}, bitstream)
    h2, manifest, bs = ff.unpack(blob)
    assert bs == bitstream and json.loads(manifest) == {"k": "v"}
    assert h2 == h
    assert ff.validate(blob)[0] == h


def test_no_manifest(bitstream):
    blob = ff.pack(header(), None, bitstream)
    assert len(blob) == 256 + len(bitstream)
    h, manifest, _ = ff.unpack(blob)
    assert manifest == b"" and h.manifest_len == 0


def test_every_single_byte_header_corruption_is_caught(bitstream):
    blob = bytearray(ff.pack(header(), {"x": 1}, bitstream))
    for i in range(256):
        bad = bytearray(blob)
        bad[i] ^= 0x01
        with pytest.raises(ff.FormatError):
            ff.unpack(bytes(bad))


def test_bitstream_flip_caught_by_crc(bitstream):
    blob = bytearray(ff.pack(header(), None, bitstream))
    blob[-1] ^= 0x80
    with pytest.raises(ff.FormatError, match="CRC32"):
        ff.unpack(bytes(blob))


def test_sha_mismatch_caught_even_if_crc_patched(bitstream):
    h = header()
    blob = bytearray(ff.pack(h, None, bitstream))
    blob[-1] ^= 0x80
    struct.pack_into("<I", blob, 20, zlib.crc32(bytes(blob[256:])))
    struct.pack_into("<I", blob, 252, zlib.crc32(bytes(blob[:252])))
    with pytest.raises(ff.FormatError, match="SHA-256"):
        ff.unpack(bytes(blob))


def test_truncated_and_extended_files_are_caught(bitstream):
    blob = ff.pack(header(), {"x": 1}, bitstream)
    with pytest.raises(ff.FormatError, match="header says"):
        ff.unpack(blob[:-1])
    with pytest.raises(ff.FormatError, match="header says"):
        ff.unpack(blob + b"\0")
    with pytest.raises(ff.FormatError, match="256 bytes"):
        ff.unpack(blob[:100])


def test_unknown_format_version_and_bad_magic(bitstream):
    blob = bytearray(ff.pack(header(), None, bitstream))
    blob[8] = 2
    struct.pack_into("<I", blob, 252, zlib.crc32(bytes(blob[:252])))
    with pytest.raises(ff.FormatError, match="format_version 2"):
        ff.unpack(bytes(blob))
    with pytest.raises(ff.FormatError, match="magic"):
        ff.unpack(bitstream)


def test_stock_kind_rules(bitstream):
    ok = ff.pack(header(kind=ff.KIND_STOCK, design_id=0xFFFF), None, bitstream)
    assert ff.validate(ok)[0].kind == 1
    with pytest.raises(ff.FormatError, match="0xFFFF"):
        ff.validate(ff.pack(header(kind=ff.KIND_STOCK, design_id=5), None, bitstream))
    with pytest.raises(ff.FormatError, match="reserved"):
        ff.validate(ff.pack(header(kind=ff.KIND_USER, design_id=0xFFFF), None, bitstream))
    with pytest.raises(ff.FormatError, match="kind 2"):
        ff.validate(ff.pack(header(kind=2), None, bitstream))


def test_validate_catches_profile_preamble_size_and_reserved(bitstream):
    with pytest.raises(ff.FormatError, match="mode code 7"):
        ff.validate(ff.pack(header(io_profile=0x7), None, bitstream))
    with pytest.raises(ff.FormatError, match="preamble"):
        ff.validate(ff.pack(header(), None, b"\xff" * len(bitstream)))
    small = fake_bitstream(size=1000)
    with pytest.raises(ff.FormatError, match="expected 102400"):
        ff.validate(ff.pack(header(), None, small))
    assert ff.validate(ff.pack(header(), None, small), size_bounds=False)[2] == small
    with pytest.raises(ff.FormatError, match="reserved"):
        ff.validate(ff.pack(header(reserved=b"\1" + b"\0" * 24), None, bitstream))
    with pytest.raises(ff.FormatError, match="not JSON"):
        ff.validate(ff.pack(header(), b"{not json", bitstream))
    with pytest.raises(ff.FormatError, match="clock_code 4"):
        ff.validate(ff.pack(header(clock_code=4), None, bitstream))
    with pytest.raises(ff.FormatError, match="capabilities"):
        ff.validate(ff.pack(header(capabilities=0x40), None, bitstream))
    with pytest.raises(ff.FormatError, match="design_version"):
        ff.validate(ff.pack(header(design_version=1000), None, bitstream))


def test_name_and_description_limits():
    with pytest.raises(ff.FormatError, match="max 31"):
        header(name="n" * 32).to_bytes()
    with pytest.raises(ff.FormatError, match="max 127"):
        header(description="d" * 128).to_bytes()
    with pytest.raises(ff.FormatError, match="ASCII"):
        header(name="café").to_bytes()
    with pytest.raises(ff.FormatError, match="design_id"):
        header(design_id=70000).to_bytes()


def test_preamble_anywhere_in_first_64_bytes():
    assert ff.has_preamble(b"\xff" * 60 + ff.ICE40_PREAMBLE)
    assert not ff.has_preamble(b"\xff" * 61 + ff.ICE40_PREAMBLE)
    assert ff.has_preamble(ff.ICE40_PREAMBLE)


def test_describe_and_cli(tmp_path, bitstream, capsys):
    blob = ff.pack(header(), {"tool": "test"}, bitstream)
    text = ff.describe(ff.Header.from_bytes(blob))
    assert "drives: GPIO26" in text and "hello_blink" in text
    f = tmp_path / "x.fwfpga"
    f.write_bytes(blob)
    assert ff.main(["inspect", str(f), "--manifest"]) == 0
    out = capsys.readouterr().out
    assert '"tool": "test"' in out
    f.write_bytes(blob[:-3])
    assert ff.main(["inspect", str(f)]) == 1
