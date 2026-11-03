import json
import struct
import tomllib
import zlib

import pytest

import check_container as cc
import design_toml as dt
import fwfpga_format as ff
import gen_design_id as gid
import pack_fwfpga as pk
from conftest import GOOD_TOML, STOCK_TOML, fake_bitstream


def design(text=GOOD_TOML):
    return dt.from_dict(tomllib.loads(text))


def test_header_from_design_matches_id_block_fields():
    d = design()
    h = pk.header_from_design(d)
    f = gid.id_block_fields(d)
    assert (h.design_id, h.design_version, h.capabilities, h.clock_code, h.io_profile) == \
           (f["design_id"], f["design_version"], f["capabilities"], f["clock_code"], f["io_profile"])
    assert h.name == "hello_blink" and h.kind == 0 and h.contract_version == 1


def test_pack_design_round_trip(bitstream):
    d = design()
    blob = pk.pack_design(d, bitstream, pk.build_manifest(d, timestamp="2026-10-31T00:00:00Z"))
    h, manifest, bs = ff.validate(blob)
    assert bs == bitstream
    m = json.loads(manifest)
    assert m["design"]["design"]["name"] == "hello_blink"
    assert m["design"]["io_profile"]["gpio26"] == "FPGA_OUT"
    assert m["built"] == "2026-10-31T00:00:00Z" and m["format"] == pk.MANIFEST_FORMAT
    assert cc.compare_with_design(h, d) == []


def test_pack_refuses_non_bitstream_and_bad_size(bitstream):
    with pytest.raises(pk.PackError, match="preamble"):
        pk.pack_design(design(), b"\x00" * len(bitstream))
    with pytest.raises(pk.PackError, match="allow-size"):
        pk.pack_design(design(), fake_bitstream(2000))
    assert pk.pack_design(design(), fake_bitstream(2000), allow_size=True)


def test_manifest_extra_merges_but_cannot_override_design():
    d = design()
    m = pk.build_manifest(d, extra={"notes": "x"}, tool_versions={"yosys": "0.70"}, timestamp="t")
    assert m["notes"] == "x" and m["tools"] == {"yosys": "0.70"}
    with pytest.raises(pk.PackError):
        pk.build_manifest(d, extra={"design": {}})


def test_source_date_epoch(monkeypatch):
    monkeypatch.setenv("SOURCE_DATE_EPOCH", "0")
    assert pk.build_timestamp() == "1970-01-01T00:00:00Z"


def test_pack_cli_and_check_cli(tmp_path, bitstream, capsys):
    ddir = tmp_path / "designs" / "hello_blink"
    ddir.mkdir(parents=True)
    (ddir / "design.toml").write_text(GOOD_TOML)
    binf = tmp_path / "hello_blink.bin"
    binf.write_bytes(bitstream)
    extra = tmp_path / "extra.json"
    extra.write_text('{"notes": "cli"}')
    out = tmp_path / "out" / "hello_blink.fwfpga"
    assert pk.main([str(ddir), str(binf), "-o", str(out), "--manifest", str(extra),
                    "--tool-versions", '{"yosys": "0.70"}']) == 0
    blob = out.read_bytes()
    h, manifest, _ = ff.validate(blob)
    assert json.loads(manifest)["notes"] == "cli"

    # default output name sits beside the .bin
    assert pk.main([str(ddir), str(binf), "--no-manifest"]) == 0
    assert (tmp_path / "hello_blink.fwfpga").exists()
    assert ff.Header.from_bytes((tmp_path / "hello_blink.fwfpga").read_bytes()).manifest_len == 0

    # check_container: explicit design, auto-found design, no design
    assert cc.main([str(out), "--design", str(ddir)]) == 0
    assert "header matches" in capsys.readouterr().out
    assert cc.main([str(out), "--designs-root", str(tmp_path / "designs")]) == 0
    assert "header matches" in capsys.readouterr().out
    assert cc.main([str(out), "--designs-root", str(tmp_path / "nowhere"), "-q"]) == 0
    assert "comparison skipped" in capsys.readouterr().out

    # a bare .bin is refused
    assert pk.main([str(ddir), str(tmp_path / "nope.bin")]) == 1
    assert cc.main([str(binf)]) == 1
    assert "magic" in capsys.readouterr().err


def test_check_detects_every_header_field_mismatch(bitstream):
    d = design()
    blob = bytearray(pk.pack_design(d, bitstream, None))
    patches = {
        "name": (56, b"hello_blin2".ljust(32, b"\0")),
        "description": (88, b"other".ljust(128, b"\0")),
        "design_id": (216, struct.pack("<H", 2)),
        "design_version": (218, struct.pack("<H", 2)),
        "capabilities": (220, b"\x01"),
        "clock_code": (221, b"\x01"),
        "io_profile": (222, struct.pack("<I", ff.Header.from_bytes(bytes(blob)).io_profile ^ 0x2)),
        "kind": (226, b"\x01"),
    }
    for field, (off, raw) in patches.items():
        bad = bytearray(blob)
        bad[off:off + len(raw)] = raw
        if field == "kind":
            bad[216:218] = struct.pack("<H", 0xFFFF)
        struct.pack_into("<I", bad, 252, zlib.crc32(bytes(bad[:252])))
        header, errors, _ = cc.check(bytes(bad), d)
        assert errors, field
        assert any(e.startswith(field + ":") for e in errors), (field, errors)


def test_check_reports_format_errors_first(bitstream):
    blob = bytearray(pk.pack_design(design(), bitstream, None))
    blob[300] ^= 1
    header, errors, notes = cc.check(bytes(blob), design())
    assert header is None and len(errors) == 1 and "CRC32" in errors[0]


def test_check_stock_container(bitstream):
    d = design(STOCK_TOML)
    blob = pk.pack_design(d, bitstream, None)
    header, errors, notes = cc.check(blob, d)
    assert errors == [] and header.kind == 1 and header.design_id == 0xFFFF
    # a stock header checked against a user design.toml fails on kind and id
    _, errors, _ = cc.check(blob, design())
    assert any(e.startswith("kind:") for e in errors) and any(e.startswith("design_id:") for e in errors)


def test_check_file_resolves_design_by_header_name(tmp_path, bitstream):
    root = tmp_path / "designs"
    (root / "hello_blink").mkdir(parents=True)
    (root / "hello_blink" / "design.toml").write_text(GOOD_TOML)
    f = tmp_path / "x.fwfpga"
    f.write_bytes(pk.pack_design(design(), bitstream, None))
    header, errors, notes = cc.check_file(f, designs_root=root)
    assert errors == [] and any("header matches" in n for n in notes)
    # description changed in the toml after the build -> mismatch
    (root / "hello_blink" / "design.toml").write_text(GOOD_TOML.replace("Blink GPIO26", "Blink GPIO27"))
    header, errors, notes = cc.check_file(f, designs_root=root)
    assert errors and errors[0].startswith("description:")
