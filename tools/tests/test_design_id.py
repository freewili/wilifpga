import tomllib

import pytest

import design_toml as dt
import gen_design_id as gid
import profile as iop
from conftest import GOOD_TOML, STOCK_TOML


def design(text=GOOD_TOML):
    return dt.from_dict(tomllib.loads(text))


def test_id_block_layout():
    d = design()
    blk = gid.id_block_for(d)
    assert len(blk) == 16
    assert blk[0:4] == b"FW2F" == bytes([0x46, 0x57, 0x32, 0x46])
    assert blk[4] == 1                                   # contract_version
    assert blk[5:7] == (1).to_bytes(2, "little")         # design_id
    assert blk[7:9] == (1).to_bytes(2, "little")         # version 001
    assert blk[9] == 3                                   # IO_BUFFER | STREAM
    assert blk[10] == 0                                  # clock code 31.25 MHz
    assert blk[11:15] == iop.pack(d.io_profile).to_bytes(4, "little")
    x = 0
    for b in blk[:15]:
        x ^= b
    assert blk[15] == x


def test_id_block_bytes_direct_values():
    blk = gid.id_block_bytes(design_id=0x1234, design_version=999, capabilities=0x1F, clock_code=3,
                             io_profile=0x2DB6DB6D)
    assert blk[5:7] == b"\x34\x12" and blk[7:9] == b"\xe7\x03"
    assert blk[9] == 0x1F and blk[10] == 3 and blk[11:15] == b"\x6d\xdb\xb6\x2d"
    assert gid.parse_id_block(blk) == dict(contract_version=1, design_id=0x1234, design_version=999,
                                           capabilities=0x1F, clock_code=3, io_profile=0x2DB6DB6D)


def test_parse_rejects_bad_magic_and_checksum():
    blk = bytearray(gid.id_block_for(design()))
    blk[15] ^= 1
    with pytest.raises(ValueError, match="checksum"):
        gid.parse_id_block(bytes(blk))
    blk = bytearray(gid.id_block_for(design()))
    blk[0] = 0
    with pytest.raises(ValueError, match="magic"):
        gid.parse_id_block(bytes(blk))
    with pytest.raises(ValueError, match="16 bytes"):
        gid.parse_id_block(b"FW2F")


def test_render_vh_has_the_exact_defines():
    d = design()
    text = gid.render_vh(d)
    blk = gid.id_block_for(d)
    for line in [
        "`define FW2_DESIGN_ID        16'd1",
        "`define FW2_DESIGN_VERSION   16'd1",
        "`define FW2_DESIGN_CAPS      8'h03",
        "`define FW2_DESIGN_CLOCK_CODE 8'd0",
        "`define FW2_DESIGN_CLOCK_HZ  31250000",
        f"`define FW2_DESIGN_IO_PROFILE 32'h{iop.pack(d.io_profile):08X}",
        f"`define FW2_DESIGN_CHECKSUM  8'h{blk[15]:02X}",
        "`define FW2_IOP_SPI_MISO 3'd1",
        "`define FW2_IOP_SPI_CS 3'd0",
        "`define FW2_IOP_GPIO26 3'd2",
        "`define FW2_IOP_GPIO27 3'd0",
    ]:
        assert line in text.splitlines(), line
    assert text.count("`define FW2_IOP_") == 10
    assert text.startswith("// fw2_design_id.vh -- GENERATED")
    assert "`ifndef FW2_DESIGN_ID_VH" in text and text.rstrip().endswith("`endif // FW2_DESIGN_ID_VH")
    assert text.isascii()


def test_stock_design_renders_ffff():
    text = gid.render_vh(design(STOCK_TOML))
    assert "`define FW2_DESIGN_ID        16'd65535" in text


def test_write_vh_and_cli(tmp_path, capsys):
    (tmp_path / "design.toml").write_text(GOOD_TOML)
    out = tmp_path / "build" / "fw2_design_id.vh"
    assert gid.main([str(tmp_path), "-o", str(out)]) == 0
    assert out.read_text() == gid.render_vh(design())
    assert gid.main([str(tmp_path), "--bytes"]) == 0
    assert capsys.readouterr().out.strip().endswith(gid.id_block_for(design()).hex(" "))
    (tmp_path / "design.toml").write_text(GOOD_TOML.replace('version = "001"', 'version = "1"'))
    assert gid.main([str(tmp_path)]) == 1
