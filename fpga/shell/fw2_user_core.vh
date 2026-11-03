// fw2_user_core.vh - the fixed user_core port list (FW2 FPGA design contract
// rule 1). Every design's user_core.v must declare exactly these ports with
// these names and widths; fw2_shell instantiates `user_core` by name.
//
//   module user_core (
//     input  wire       clk,          // FPGA_CLK pad (31.25 MHz unless design.toml says otherwise)
//     input  wire       rst_n,        // active-low synchronous reset: power-up and register 0x01
//     // Header (outer net, through the level shifters). Index = FW2_SIG_* (0 spi_miso .. 9 gpio27).
//     input  wire [9:0] hdr_in,       // level of every _Out pad (meaningful for FPGA_IN; readback otherwise)
//     output wire [9:0] hdr_out,      // value driven on _Out pads whose mode is FPGA_OUT
//     output wire [9:0] hdr_oe,       // per-signal output enable, honoured only for FPGA_OUT and only while IO_ARM=1
//     // Inner net (direct RP2350 <-> FPGA), LINK modes only
//     input  wire [9:0] rp_in,        // level of every _Rp pad (meaningful for LINK_RP2F; readback otherwise)
//     output wire [9:0] rp_out,       // value driven on _Rp pads whose mode is LINK_F2RP, while IO_ARM=1
//     // User register window 0x10-0x5F. reg_addr is the ABSOLUTE 7-bit bus address.
//     input  wire [6:0] reg_addr,     // current bus address (combinational lookup for reg_rdata)
//     input  wire [7:0] reg_wdata,
//     input  wire       reg_wr,       // one-cycle pulse: reg_wdata was written to reg_addr (0x10-0x5F only)
//     input  wire       reg_rd,       // one-cycle pulse: the byte at reg_addr has just been shifted to the host
//     output wire [7:0] reg_rdata,    // must be a combinational function of reg_addr (and state); sampled by the shell
//     // Stream FIFO, names from the host's point of view (register 0x60 "TX" = host -> FPGA)
//     input  wire [7:0] fifo_tx_data, // host -> FPGA byte at the head of the TX FIFO
//     input  wire       fifo_tx_valid,
//     output wire       fifo_tx_ready,// pop (consumes fifo_tx_data when fifo_tx_valid)
//     output wire [7:0] fifo_rx_data, // FPGA -> host byte to push
//     output wire       fifo_rx_valid,// push: accepted in a cycle where fifo_rx_ready is ALSO high; hold valid/data until then
//     input  wire       fifo_rx_ready
//   );
//
// Rules: never reference a pad name from fw2.pcf; never derive a direction from
// anything but design.toml (the shell ties off every pad the profile does not
// hand to you); drive unused outputs to 0; keep every register read side-effect
// free unless you use reg_rd. All clock domains are `clk`; the shell has no PLL.
// Stream handshake: a byte is pushed in exactly the cycles fifo_rx_valid &&
// fifo_rx_ready are both 1 (ready = FIFO not full). Decide on THIS cycle's
// ready, not last cycle's: a core that samples ready and asserts valid one
// clock later can push into a FIFO that just filled (byte lost, RX_OVERRUN).
// Likewise fifo_tx_ready pops fifo_tx_data in the cycle both it and
// fifo_tx_valid are high.
`ifndef FW2_USER_CORE_VH
`define FW2_USER_CORE_VH
`define FW2_USER_CORE_CONTRACT_VERSION 1
`endif
