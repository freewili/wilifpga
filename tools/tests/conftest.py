"""Shared fixtures for the tools tests: tools/ on sys.path, a valid design.toml, a fake bitstream."""
import sys
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parents[1]
REPO = TOOLS.parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

GOOD_TOML = '''\
[design]
name = "hello_blink"
description = "Blink GPIO26 from the fabric; first bitfile tutorial."
version = "001"
design_id = 1
kind = "user"
clock_hz = 31250000
capabilities = ["IO_BUFFER", "STREAM"]
repository = "https://github.com/freewili/wilifpga"

[io_profile]
spi_miso = "PASS_IN"
spi_cs = "PASS_OUT"
spi_sclk = "PASS_OUT"
spi_mosi = "PASS_OUT"
uart_tx = "PASS_OUT"
uart_rx = "PASS_IN"
uart_cts = "PASS_IN"
uart_rts = "PASS_OUT"
gpio26 = "FPGA_OUT"
gpio27 = "PASS_OUT"
'''

STOCK_TOML = '''\
[design]
name = "stock_example"
description = "The stock gateware rebuilt with this flow."
version = "001"
design_id = 65535
kind = "stock"
clock_hz = 31250000
capabilities = ["IO_BUFFER", "PSRAM_SWAP", "CM0", "I2C_SLAVE"]
repository = "https://github.com/freewili/wilifpga"

[io_profile]
spi_miso = "PASS_IN"
spi_cs = "PASS_OUT"
spi_sclk = "PASS_OUT"
spi_mosi = "PASS_OUT"
uart_tx = "PASS_OUT"
uart_rx = "PASS_IN"
uart_cts = "PASS_IN"
uart_rts = "PASS_OUT"
gpio26 = "PASS_IN"
gpio27 = "PASS_OUT"
'''


def fake_bitstream(size=104090, seed=7):
    """Looks like an iCE40 image: FF 00 00 FF 7E AA 99 7E then deterministic filler."""
    import random
    rnd = random.Random(seed)
    head = bytes([0xFF, 0x00, 0x00, 0xFF, 0x7E, 0xAA, 0x99, 0x7E])
    body = bytes(rnd.getrandbits(8) for _ in range(size - len(head)))
    return head + body


@pytest.fixture
def good_toml_text():
    return GOOD_TOML


@pytest.fixture
def design_dir(tmp_path):
    d = tmp_path / "designs" / "hello_blink"
    d.mkdir(parents=True)
    (d / "design.toml").write_text(GOOD_TOML, encoding="utf-8")
    (d / "user_core.v").write_text(
        "module user_core(input clk, input rst_n, output [9:0] hdr_out);\n"
        "  reg [23:0] c; always @(posedge clk) c <= c + 1;\n"
        "  assign hdr_out = {1'b0, c[23], 8'b0};\nendmodule\n", encoding="ascii")
    (d / "tb").mkdir()
    (d / "tb" / "tb_user_core.v").write_text("module tb; wire SPI_CS_Rp; initial $finish; endmodule\n")
    return d


@pytest.fixture
def stock_dir(tmp_path):
    d = tmp_path / "designs" / "stock_example"
    d.mkdir(parents=True)
    (d / "design.toml").write_text(STOCK_TOML, encoding="utf-8")
    (d / "main.v").write_text("module main(input CLK, output GPIO_26_Out); assign GPIO_26_Out = CLK; endmodule\n")
    return d


@pytest.fixture
def bitstream():
    return fake_bitstream()
