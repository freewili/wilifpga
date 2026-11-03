"""The generated C header parses what the Python packer writes (host gcc; skipped when none is found)."""
import os
import shutil
import struct
import subprocess
import sys
import tomllib
import zlib
from pathlib import Path

import pytest

import design_toml as dt
import gen_design_id as gid
import gen_fwfpga_format_h as genh
import pack_fwfpga as pk
from conftest import GOOD_TOML, REPO

C_SRC = Path(__file__).resolve().parent / "c" / "test_fwfpga_format.c"
GCC_CANDIDATES = ["gcc", "cc", "C:/msys64/mingw64/bin/gcc.exe", "C:/msys64/ucrt64/bin/gcc.exe", "clang"]


def find_gcc():
    env = os.environ.get("FW2_TEST_CC")
    if env:
        return env
    for c in GCC_CANDIDATES:
        p = shutil.which(c) or (c if Path(c).is_file() else None)
        if p:
            return p
    return None


GCC = find_gcc()
pytestmark = pytest.mark.skipif(GCC is None, reason="no host C compiler found")


def test_checked_in_header_is_current():
    assert genh.DEFAULT_OUT.exists(), "run tools/gen_fwfpga_format_h.py"
    assert genh.DEFAULT_OUT.read_text(encoding="ascii") == genh.render()


@pytest.fixture(scope="module")
def binary(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("c")
    exe = tmp / ("t.exe" if os.name == "nt" else "t")
    header_dir = tmp / "inc"
    header_dir.mkdir()
    (header_dir / "fw2_fwfpga_format.h").write_text(genh.render(), encoding="ascii")
    cmd = [GCC, "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", str(header_dir), str(C_SRC), "-o", str(exe)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    return exe


def run(binary, path):
    r = subprocess.run([str(binary), str(path)], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    assert r.returncode == 0, r.stderr
    out = {}
    for line in r.stdout.splitlines():
        k, _, v = line.partition("=")
        out[k] = v
    return out


def test_c_parses_python_container(binary, tmp_path, bitstream):
    d = dt.from_dict(tomllib.loads(GOOD_TOML))
    blob = pk.pack_design(d, bitstream, pk.build_manifest(d, timestamp="t"))
    f = tmp_path / "x.fwfpga"
    f.write_bytes(blob)
    out = run(binary, f)
    assert out["sizeof_header"] == "256"
    assert out["valid"] == "1" and out["valid_fnptr_agrees"] == "1"
    assert out["fields_ok"] == "1", out["reason"]
    assert out["name"] == "hello_blink"
    assert out["description"] == d.description
    assert out["design_id"] == "1" and out["design_version"] == "1"
    assert out["capabilities"] == "3" and out["clock_code"] == "0" and out["clock_hz"] == "31250000"
    assert int(out["io_profile"], 16) == d.io_profile_packed
    assert out["kind"] == "0"
    assert out["manifest_len"] == str(struct.unpack_from("<I", blob, 12)[0])
    assert out["bitstream_len"] == str(len(bitstream))
    assert int(out["bitstream_crc32"], 16) == zlib.crc32(bitstream)
    assert int(out["header_crc32"], 16) == zlib.crc32(blob[:252])
    assert out["lengths_ok"] == "1" and out["bitstream_crc_ok"] == "1" and out["preamble_ok"] == "1"
    assert out["mode_gpio26"] == "2" and out["mode_spi_miso"] == "1"
    assert out["idblk"] == gid.id_block_for(d).hex()
    assert out["idblk_match"] == "0"
    assert out["idblk_profile_mismatch"] == "8"   # FW2_IDBLK_MISMATCH_IO_PROFILE
    assert out["idblk_bad_checksum"] == "2"       # FW2_IDBLK_BAD_CHECKSUM


def test_c_rejects_corruption(binary, tmp_path, bitstream):
    d = dt.from_dict(tomllib.loads(GOOD_TOML))
    blob = bytearray(pk.pack_design(d, bitstream, None))
    f = tmp_path / "bad.fwfpga"
    for i in (0, 8, 10, 100, 222, 251):
        bad = bytearray(blob)
        bad[i] ^= 1
        f.write_bytes(bad)
        assert run(binary, f)["valid"] == "0", i
    # bitstream flip: header still valid, payload CRC fails
    bad = bytearray(blob)
    bad[-1] ^= 1
    f.write_bytes(bad)
    out = run(binary, f)
    assert out["valid"] == "1" and out["bitstream_crc_ok"] == "0"
    # truncated: lengths disagree
    f.write_bytes(blob[:-10])
    assert run(binary, f)["lengths_ok"] == "0"
    # bare bitstream
    f.write_bytes(bitstream)
    assert run(binary, f)["valid"] == "0"
    # kind=stock with a user id fails the field check
    bad = bytearray(blob)
    bad[226] = 1
    struct.pack_into("<I", bad, 252, zlib.crc32(bytes(bad[:252])))
    f.write_bytes(bad)
    out = run(binary, f)
    assert out["valid"] == "1" and out["fields_ok"] == "0" and out["reason"] == "stock design_id"
