import tomllib

import pytest

import design_toml as dt
from conftest import GOOD_TOML, STOCK_TOML


def load(text):
    return dt.from_dict(tomllib.loads(text))


def mutate(text, old, new):
    assert old in text, old
    return text.replace(old, new, 1)


def test_good_design_loads():
    d = load(GOOD_TOML)
    assert d.name == "hello_blink" and d.version == 1 and d.version_str == "001"
    assert d.design_id == 1 and d.kind == "user" and d.clock_code == 0
    assert d.capabilities == ["IO_BUFFER", "STREAM"] and d.caps_byte == 3
    assert d.io_profile["gpio26"] == "FPGA_OUT"
    assert d.kind_code == 0 and not d.is_stock


def test_stock_design_loads():
    d = load(STOCK_TOML)
    assert d.is_stock and d.design_id == 0xFFFF and d.kind_code == 1
    assert d.caps_byte == 1 | 4 | 8 | 16


def test_cm0_needs_the_stock_clock():
    cm0 = mutate(GOOD_TOML, '["IO_BUFFER", "STREAM"]', '["IO_BUFFER", "CM0"]')
    assert load(cm0).caps_byte == 1 | 8
    for hz in (12500000, 25000000, 48000000):
        assert load(mutate(GOOD_TOML, "clock_hz", f"clock_hz = {hz}  #")).clock_hz == hz
        with pytest.raises(dt.DesignError, match="CM0 needs clock_hz"):
            load(mutate(cm0, "clock_hz", f"clock_hz = {hz}  #"))


def test_capabilities_are_canonically_ordered():
    d = load(mutate(GOOD_TOML, '["IO_BUFFER", "STREAM"]', '["STREAM", "IO_BUFFER"]'))
    assert d.capabilities == ["IO_BUFFER", "STREAM"]


@pytest.mark.parametrize("old,new,msg", [
    ('version = "001"', 'version = "01"', "three digits"),
    ('version = "001"', 'version = "0001"', "three digits"),
    ('version = "001"', 'version = 1', "three digits"),
    ('description = "Blink GPIO26 from the fabric; first bitfile tutorial."', 'description = ""', "required"),
    ('design_id = 1', 'design_id = 65536', "0..65535"),
    ('design_id = 1', 'design_id = 65535', "reserved"),
    ('kind = "user"', 'kind = "stock"', "0xFFFF"),
    ('kind = "user"', 'kind = "other"', "kind"),
    ('clock_hz = 31250000', 'clock_hz = 30000000', "clock_hz"),
    ('["IO_BUFFER", "STREAM"]', '["IO_BUFFER", "LASER"]', "unknown name"),
    ('["IO_BUFFER", "STREAM"]', '["IO_BUFFER", "IO_BUFFER"]', "twice"),
    ('["IO_BUFFER", "STREAM"]', '"IO_BUFFER"', "list"),
    ('gpio26 = "FPGA_OUT"', 'gpio26 = "fpga_out"', "gpio26"),
    ('name = "hello_blink"', 'name = "' + "x" * 32 + '"', "max 31"),
    ('name = "hello_blink"', 'name = "hello blink"', "letters"),
    ('name = "hello_blink"', 'name = "héllo"', "ASCII"),
    ('repository = "https://github.com/freewili/wilifpga"', 'repository = ""', "required"),
])
def test_malformed_fields_are_rejected(old, new, msg):
    with pytest.raises(dt.DesignError, match=msg):
        load(mutate(GOOD_TOML, old, new))


def test_description_max_127():
    ok = mutate(GOOD_TOML, 'description = "Blink GPIO26 from the fabric; first bitfile tutorial."',
                'description = "' + "d" * 127 + '"')
    assert len(load(ok).description) == 127
    with pytest.raises(dt.DesignError, match="max 127"):
        load(mutate(ok, "d" * 127, "d" * 128))


def test_missing_required_key_and_missing_profile_signal():
    with pytest.raises(dt.DesignError, match="missing: description"):
        load(mutate(GOOD_TOML, 'description = "Blink GPIO26 from the fabric; first bitfile tutorial."\n', ""))
    with pytest.raises(dt.DesignError, match="missing: gpio27"):
        load(mutate(GOOD_TOML, 'gpio27 = "PASS_OUT"\n', ""))
    with pytest.raises(dt.DesignError, match="missing \\[io_profile\\]"):
        load(GOOD_TOML.split("[io_profile]")[0])


def test_unknown_keys_and_tables_are_errors():
    with pytest.raises(dt.DesignError, match="unknown key"):
        load(mutate(GOOD_TOML, 'kind = "user"', 'kind = "user"\nauthor = "me"'))
    with pytest.raises(dt.DesignError, match="unknown top-level"):
        load(GOOD_TOML + '\n[extra]\nx = 1\n')


def test_optional_build_hints():
    d = load(GOOD_TOML)
    assert d.top is None and d.sources == [] and d.include_dirs == []
    assert "top" not in d.toml_echo()["design"]
    text = mutate(GOOD_TOML, 'kind = "user"', 'kind = "user"\ntop = "main"\nsources = ["a.v", "b.v"]\ninclude_dirs = ["fpga/lib/x"]')
    d = load(text)
    assert d.top == "main" and d.sources == ["a.v", "b.v"] and d.include_dirs == ["fpga/lib/x"]
    assert d.toml_echo()["design"]["sources"] == ["a.v", "b.v"]
    with pytest.raises(dt.DesignError, match="design.top"):
        load(mutate(GOOD_TOML, 'kind = "user"', 'kind = "user"\ntop = "not a module"'))
    with pytest.raises(dt.DesignError, match="design.sources"):
        load(mutate(GOOD_TOML, 'kind = "user"', 'kind = "user"\nsources = "a.v"'))
    with pytest.raises(dt.DesignError, match="design.include_dirs"):
        load(mutate(GOOD_TOML, 'kind = "user"', 'kind = "user"\ninclude_dirs = [1]'))


def test_kind_defaults_to_user_and_registers_table_is_kept():
    text = mutate(GOOD_TOML, 'kind = "user"\n', "") + '\n[registers]\n0x10 = "blink period"\n'
    d = load(text)
    assert d.kind == "user"
    assert d.extras == {"registers": {"0x10": "blink period"}}
    assert d.toml_echo()["registers"] == {"0x10": "blink period"}


def test_load_design_from_dir_and_errors(tmp_path):
    (tmp_path / "design.toml").write_text(GOOD_TOML)
    assert dt.load_design(tmp_path).name == "hello_blink"
    assert dt.load_design(tmp_path / "design.toml").path == tmp_path / "design.toml"
    with pytest.raises(dt.DesignError, match="not found"):
        dt.load_design(tmp_path / "nope")
    (tmp_path / "design.toml").write_text("[design\n")
    with pytest.raises(dt.DesignError):
        dt.load_design(tmp_path)


def test_caps_byte_round_trip():
    assert dt.caps_from_byte(dt.caps_to_byte(["CM0", "STREAM"])) == ["STREAM", "CM0"]
    with pytest.raises(dt.DesignError):
        dt.caps_from_byte(0x40)


def test_cli(tmp_path, capsys):
    (tmp_path / "design.toml").write_text(GOOD_TOML)
    assert dt.main([str(tmp_path)]) == 0
    assert "drives: GPIO26" in capsys.readouterr().out
    (tmp_path / "design.toml").write_text(mutate(GOOD_TOML, 'version = "001"', 'version = "1"'))
    assert dt.main([str(tmp_path)]) == 1
