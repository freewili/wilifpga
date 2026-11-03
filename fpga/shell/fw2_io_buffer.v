// ---------------------------------------------------------------------------
// fw2_io_buffer.v - profile-driven, arm-gated direction logic for the ten
// FreeWili 2 header signals. Replaces the stock io_buffer inside fw2_shell.
// The pads themselves stay in fw2_shell (scalar `assign PAD = oe ? o : 1'bz`,
// exactly the stock idiom, which yosys maps to bidirectional SB_IO); this
// module only computes per-signal output values and output enables.
//
// PROVENANCE: a rewrite of io_buffer.v from the stock gateware repository
// "freewilifpga" (fpga/src/dsn/io_buffer.v, Adam Kidwell). Kept from the stock core, verified against its
// Verilog (docs/drivers/shell.md):
//   * pad pairing: <sig>_rp (inner net, RP2350) <-> <sig>_out (outer net, header);
//   * passthrough: PASS_OUT drives _out from _rp, PASS_IN drives _rp from _out;
//   * the IO_CONFIG_ENABLE window takes the four SPI1 inner nets for the
//     register bus: spi_miso_rp is driven by the bus MISO, the other three SPI
//     _rp pads and the PASS_OUT SPI _out pads release;
//   * DIR ball polarity: 1 = FPGA drives the header (_out output enabled),
//     0 = header drives the board (stock: gpio_27_dir = gpio_27_out_dir).
// Different:
//   * directions are compile-time constants from the IO profile (PROFILE
//     parameter, 10 x 3 bits), not a writable register; dir_bits gives the
//     stock-format readback for registers 0x02/0x03;
//   * every output enable and both DIR balls are ANDed with arm (contract
//     rule 9); the single exception is spi_miso_rp inside the window;
//   * FPGA_OUT / FPGA_IN / LINK_* modes hand the pad to the user core bundles;
//   * no HSBDIO (GPIO26 direction following GPIO27) and no swap flag on CTS.
// ---------------------------------------------------------------------------
`include "fw2_profile.vh"

module fw2_io_buffer
#
(
  parameter [29:0] PROFILE = {10{`FW2_MODE_OFF}}
)
(
  input  wire       io_config_enable,
  input  wire       arm,              // 0: every pad is an input (except MISO in the config window)
  input  wire       spi_miso_bus,     // register-bus MISO (driven onto spi_miso_rp inside the window)
  // Pad values, index = FW2_SIG_* (0 spi_miso, 1 spi_cs, 2 spi_sclk, 3 spi_mosi,
  // 4 uart_tx, 5 uart_rx, 6 uart_cts, 7 uart_rts, 8 gpio26, 9 gpio27)
  input  wire [9:0] rp_i,             // inner net pad levels (RP2350 side)
  output wire [9:0] rp_o,             // value to drive when rp_oe
  output wire [9:0] rp_oe,
  input  wire [9:0] hdr_i,            // outer net pad levels (header side, before the shifter)
  output wire [9:0] hdr_o,
  output wire [9:0] hdr_oe_pad,
  output wire       gpio_26_dir,      // level-shifter DIR balls: 1 = toward header
  output wire       gpio_27_dir,
  // User core bundles
  output wire [9:0] hdr_in,
  input  wire [9:0] hdr_out,
  input  wire [9:0] hdr_oe,
  output wire [9:0] rp_in,
  input  wire [9:0] rp_out,
  // Stock register 0x02/0x03 readback: 1 = FPGA drives the _out pad (header side)
  output wire [9:0] dir_bits
);

genvar i;
generate
  for (i = 0; i < 10; i = i + 1) begin : g_sig
    localparam [2:0] MODE    = PROFILE[3*i+2 -: 3];
    localparam       IS_SPI  = (i < 4);
    localparam       IS_MISO = (i == `FW2_SIG_SPI_MISO);

    // The register-bus window owns the four SPI inner nets regardless of arm
    wire cfg = IS_SPI ? io_config_enable : 1'b0;

    wire rp_pass  = (MODE == `FW2_MODE_PASS_IN);
    wire rp_link  = (MODE == `FW2_MODE_LINK_F2RP);
    wire hdr_pass = (MODE == `FW2_MODE_PASS_OUT);
    wire hdr_user = (MODE == `FW2_MODE_FPGA_OUT) & hdr_oe[i];

    // Inner net: the only pad allowed to drive while disarmed is spi_miso_rp
    // inside the window (register bus read data).
    assign rp_oe[i] = cfg ? (IS_MISO ? 1'b1 : 1'b0)
                          : (arm & (rp_pass | rp_link));
    assign rp_o[i]  = cfg ? spi_miso_bus
                          : (rp_pass ? hdr_i[i] : rp_out[i]);

    // Outer net: PASS_OUT repeats the inner net except while the window has
    // borrowed the SPI inner nets (stock behaviour); FPGA_OUT keeps driving
    // through the window because it does not depend on the inner net.
    assign hdr_oe_pad[i] = arm & ((hdr_pass & ~cfg) | hdr_user);
    assign hdr_o[i]      = hdr_pass ? rp_i[i] : hdr_out[i];

    assign hdr_in[i]   = hdr_i[i];
    assign rp_in[i]    = rp_i[i];
    assign dir_bits[i] = (MODE == `FW2_MODE_PASS_OUT) | (MODE == `FW2_MODE_FPGA_OUT);
  end
endgenerate

// DIR balls: toward header only when armed and the FPGA drives that header pin
assign gpio_26_dir = arm & dir_bits[`FW2_SIG_GPIO26];
assign gpio_27_dir = arm & dir_bits[`FW2_SIG_GPIO27];

endmodule
