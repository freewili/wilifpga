// ---------------------------------------------------------------------------
// PROVENANCE: derived from rst_ctrl_reg.v of the FreeWili stock gateware
// repository "freewilifpga" (fpga/src/dsn/rst_ctrl_reg.v, snapshot 2026-10-31,
// authored by Jason Rosenkranz). Local changes (FW2 shell):
//   1. The reset request bit is self-clearing. In the stock core ctrl_data[0]
//      is only cleared by a later write to a DIFFERENT address, so after a
//      0x01 write resetn toggles 0/1 every clock until the host writes again
//      (latent in stock: the firmware never calls resetDir). Here a write of
//      bit0=1 yields exactly one low cycle of resetn.
//   2. The read mux is a constant 0x00 wire (lint tidy).
// Register semantics are unchanged: write bit0=1 to 0x01 for a one-cycle
// synchronous reset; reads return 0x00.
// ---------------------------------------------------------------------------

module fw2_rst_ctrl_reg
#
(
  parameter [6:0] G_SPI_BASEADDR = 7'h01
)
(
  input  wire       clk,
  output reg        resetn = 1'b0,   // Power-up reset: iCE40 regs init to 0, so the
                                     // design sees one guaranteed reset cycle at boot
  // Internal SPI signals
  input  wire       io_config_enable,
  input  wire       wr,
  input  wire [6:0] addr,
  /* verilator lint_off UNUSEDSIGNAL */
  input  wire [7:0] wr_data,         // only bit 0 is a reset request
  /* verilator lint_on UNUSEDSIGNAL */
  input  wire       data_valid,
  output wire [7:0] rd_data
);

reg reset_req = 1'b0;

// SPI write data control: latch a reset request
always @(posedge clk) begin
  if (io_config_enable == 1'b1 && wr == 1'b1 && data_valid == 1'b1 && addr == G_SPI_BASEADDR) begin
    reset_req <= wr_data[0];
  end else begin
    reset_req <= 1'b0;
  end
end

// Reads of this address always return 0x00 (the request bit never stays set)
assign rd_data = 8'h00;

// One-cycle resetn dip per request (requests arrive at most once per SPI byte)
always @(posedge clk) begin
  resetn <= ~reset_req;
end

endmodule
