import pytest

import check_design as cd
from conftest import GOOD_TOML, STOCK_TOML


def run(design_dir, pcf=None):
    return cd.check_design(design_dir, designs_root=design_dir.parent, pcf_path=pcf)


def test_good_design_passes(design_dir):
    design, errors = run(design_dir)
    assert errors == [] and design.name == "hello_blink"


def test_pad_name_in_user_file_is_rejected(design_dir):
    (design_dir / "user_core.v").write_text(
        "module user_core(output GPIO_26_Out); assign GPIO_26_Out = 1'b1; endmodule\n")
    _, errors = run(design_dir)
    assert any("GPIO_26_Out" in e and "user_core.v:1" in e for e in errors)
    # the same pad name in a comment or as part of a longer identifier is fine
    (design_dir / "user_core.v").write_text(
        "// drives GPIO_26_Out through the shell\n/* SPI_CS_Rp */\n"
        "module user_core(output my_GPIO_26_Out_copy); assign my_GPIO_26_Out_copy = 1'b1; endmodule\n")
    _, errors = run(design_dir)
    assert errors == []


def test_pad_names_come_from_pcf_when_present(design_dir, tmp_path):
    pcf = tmp_path / "fw2.pcf"
    pcf.write_text("# comment\nset_io --warn-no-port MY_SPECIAL_PAD 12\nset_io CLK 37\n")
    assert cd.pad_names(pcf) == ["MY_SPECIAL_PAD", "CLK"]
    (design_dir / "user_core.v").write_text("module user_core(output MY_SPECIAL_PAD); endmodule\n")
    _, errors = run(design_dir, pcf)
    assert any("MY_SPECIAL_PAD" in e for e in errors)
    assert cd.pad_names(tmp_path / "missing.pcf") == list(cd.KNOWN_PADS)
    assert "SRAM_IO3" in cd.KNOWN_PADS and "IO_CONFIG_ENABLE" in cd.KNOWN_PADS


def test_testbench_may_name_pads(design_dir):
    (design_dir / "tb" / "tb_user_core.v").write_text("module tb; reg SPI_CS_Rp, GPIO_26_Out; endmodule\n")
    _, errors = run(design_dir)
    assert errors == []


def test_two_digit_version_rejected(design_dir):
    (design_dir / "design.toml").write_text(GOOD_TOML.replace('version = "001"', 'version = "01"'))
    design, errors = run(design_dir)
    assert design is None and "three digits" in errors[0]


def test_duplicate_design_id_rejected(design_dir):
    other = design_dir.parent / "other"
    other.mkdir()
    (other / "design.toml").write_text(GOOD_TOML.replace('name = "hello_blink"', 'name = "other"'))
    (other / "user_core.v").write_text("module user_core; endmodule\n")
    _, errors = run(design_dir)
    assert any("design_id 1 is also used by designs/other" in e for e in errors)
    _, errors = run(other)
    assert any("designs/hello_blink" in e for e in errors)


def test_name_must_match_folder(design_dir):
    (design_dir / "design.toml").write_text(GOOD_TOML.replace('name = "hello_blink"', 'name = "blinky"'))
    _, errors = run(design_dir)
    assert any("folder name" in e for e in errors)


def test_user_design_needs_user_core_and_no_top(design_dir):
    (design_dir / "user_core.v").write_text("module fw2_shell; endmodule\nmodule main; endmodule\n")
    _, errors = run(design_dir)
    assert any("module fw2_shell" in e for e in errors)
    assert any("module main" in e for e in errors)
    assert any("module user_core" in e for e in errors)
    (design_dir / "user_core.v").unlink()
    _, errors = run(design_dir)
    assert any("no Verilog sources" in e for e in errors)


def test_stock_design_is_exempt_from_pad_rule(stock_dir):
    design, errors = run(stock_dir)
    assert errors == [] and design.is_stock
    (stock_dir / "design.toml").write_text(STOCK_TOML.replace("design_id = 65535", "design_id = 7"))
    design, errors = run(stock_dir)
    assert design is None and "0xFFFF" in errors[0]


def test_cli(design_dir, capsys):
    assert cd.main([str(design_dir), "--designs-root", str(design_dir.parent), "--pcf", "none.pcf"]) == 0
    assert "OK" in capsys.readouterr().out
    (design_dir / "user_core.v").write_text("module user_core(output SPI_CS_Out); endmodule\n")
    assert cd.main([str(design_dir), "--designs-root", str(design_dir.parent), "--pcf", "none.pcf"]) == 1
    assert "SPI_CS_Out" in capsys.readouterr().err
    assert cd.main([str(design_dir / "missing")]) == 1
