import pytest

import profile as iop


def test_signal_order_and_mode_codes_are_the_contract():
    assert iop.SIGNAL_NAMES == ("spi_miso", "spi_cs", "spi_sclk", "spi_mosi", "uart_tx", "uart_rx",
                                "uart_cts", "uart_rts", "gpio26", "gpio27")
    assert iop.MODES == {"PASS_OUT": 0, "PASS_IN": 1, "FPGA_OUT": 2, "FPGA_IN": 3,
                         "LINK_RP2F": 4, "LINK_F2RP": 5, "OFF": 6}


def test_pack_puts_signal_i_in_bits_3i():
    prof = dict(iop.STOCK_PROFILE)
    prof["gpio27"] = "OFF"        # index 9 -> bits 29:27 = 6
    prof["spi_miso"] = "FPGA_IN"  # index 0 -> bits 2:0 = 3
    v = iop.pack(prof)
    assert v & 0x7 == 3
    assert (v >> 27) & 0x7 == 6
    assert v >> 30 == 0


def test_stock_profile_packed_value():
    # miso=1 cs=0 sclk=0 mosi=0 tx=0 rx=1 cts=1 rts=0 g26=1 g27=0
    expected = (1 << 0) | (1 << 15) | (1 << 18) | (1 << 24)
    assert iop.pack(iop.STOCK_PROFILE) == expected


@pytest.mark.parametrize("modes", [
    ["PASS_OUT"] * 10, ["OFF"] * 10, ["LINK_F2RP"] * 10,
    ["PASS_OUT", "PASS_IN", "FPGA_OUT", "FPGA_IN", "LINK_RP2F", "LINK_F2RP", "OFF", "PASS_OUT", "FPGA_IN", "OFF"],
])
def test_round_trip(modes):
    prof = dict(zip(iop.SIGNAL_NAMES, modes))
    assert iop.unpack(iop.pack(prof)) == prof


def test_unpack_rejects_code_7_and_high_bits():
    with pytest.raises(iop.ProfileError):
        iop.unpack(0x7)
    with pytest.raises(iop.ProfileError):
        iop.unpack(1 << 30)
    with pytest.raises(iop.ProfileError):
        iop.unpack(1 << 40)


def test_validate_requires_all_ten_and_no_extras():
    p = dict(iop.STOCK_PROFILE)
    del p["gpio26"]
    with pytest.raises(iop.ProfileError, match="missing: gpio26"):
        iop.validate(p)
    p = dict(iop.STOCK_PROFILE, gpio28="OFF")
    with pytest.raises(iop.ProfileError, match="unknown signals: gpio28"):
        iop.validate(p)
    p = dict(iop.STOCK_PROFILE, gpio26="fpga_out")
    with pytest.raises(iop.ProfileError, match="gpio26"):
        iop.validate(p)


def test_derived_table_matches_spec_4_2():
    t = iop.MODE_TABLE
    assert t["PASS_OUT"]["rp_dir"] == "out" and t["PASS_OUT"]["fpga_rp_dir"] == "in"
    assert t["PASS_OUT"]["fpga_out_dir"] == "out" and t["PASS_OUT"]["shifter_dir"] == "to_header"
    assert t["PASS_IN"]["rp_dir"] == "in" and t["PASS_IN"]["fpga_rp_dir"] == "out"
    assert t["PASS_IN"]["fpga_out_dir"] == "in" and t["PASS_IN"]["shifter_dir"] == "to_board"
    assert t["FPGA_OUT"] == dict(rp_dir="in_nopull", fpga_rp_dir="z", fpga_out_dir="out",
                                 shifter_dir="to_header", use=t["FPGA_OUT"]["use"])
    assert t["FPGA_IN"]["fpga_out_dir"] == "in" and t["FPGA_IN"]["shifter_dir"] == "to_board"
    assert t["LINK_RP2F"]["rp_dir"] == "out" and t["LINK_RP2F"]["fpga_rp_dir"] == "in"
    assert t["LINK_RP2F"]["fpga_out_dir"] == "z" and t["LINK_RP2F"]["shifter_dir"] == "to_board"
    assert t["LINK_F2RP"]["rp_dir"] == "in" and t["LINK_F2RP"]["fpga_rp_dir"] == "out"
    assert t["OFF"] == dict(rp_dir="in", fpga_rp_dir="z", fpga_out_dir="z", shifter_dir="to_board", use="unused")
    # Only modes with the FPGA driving the header turn the shifter toward it.
    assert {m for m, r in t.items() if r["shifter_dir"] == "to_header"} == {"PASS_OUT", "FPGA_OUT"}


def test_derived_per_signal():
    d = iop.derived(iop.STOCK_PROFILE)
    assert d["spi_cs"]["rp_dir"] == "out"
    assert d["spi_miso"]["fpga_rp_dir"] == "out"
    assert set(d) == set(iop.SIGNAL_NAMES)


def test_summary_line():
    p = dict(iop.STOCK_PROFILE, spi_cs="FPGA_OUT", uart_tx="FPGA_OUT", gpio26="FPGA_IN")
    assert iop.summary(p) == "drives: SPI1 CS, UART1 TX; reads: GPIO26"
    assert iop.summary(iop.STOCK_PROFILE) == "stock passthrough"
    p = dict(iop.STOCK_PROFILE, gpio26="LINK_F2RP", gpio27="OFF")
    assert iop.summary(p) == "link: GPIO26; off: GPIO27"


def test_cli_summary(capsys):
    assert iop.main(["summary", hex(iop.pack(iop.STOCK_PROFILE))]) == 0
    out = capsys.readouterr().out
    assert "stock passthrough" in out and "SPI1 MISO" in out
