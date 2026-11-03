// user_core.v - design "template": the smallest useful FW2 design.
// One read/write register at 0x10 whose bit 0 drives GPIO26 on the header
// (profile: gpio26 = FPGA_OUT, everything else stock passthrough).
// Port list is fixed by fpga/shell/fw2_user_core.vh; never touch pad names.
`include "fw2_profile.vh"

module user_core
(
  input  wire       clk,
  input  wire       rst_n,
  input  wire [9:0] hdr_in,
  output wire [9:0] hdr_out,
  output wire [9:0] hdr_oe,
  input  wire [9:0] rp_in,
  output wire [9:0] rp_out,
  input  wire [6:0] reg_addr,
  input  wire [7:0] reg_wdata,
  input  wire       reg_wr,
  input  wire       reg_rd,
  output wire [7:0] reg_rdata,
  input  wire [7:0] fifo_tx_data,
  input  wire       fifo_tx_valid,
  output wire       fifo_tx_ready,
  output wire [7:0] fifo_rx_data,
  output wire       fifo_rx_valid,
  input  wire       fifo_rx_ready
);

localparam [6:0] REG_CTRL = 7'h10;   // bit0: level driven on GPIO26

reg [7:0] ctrl = 8'h00;

always @(posedge clk) begin
  if (!rst_n) begin
    ctrl <= 8'h00;
  end else if (reg_wr && reg_addr == REG_CTRL) begin
    ctrl <= reg_wdata;
  end
end

assign reg_rdata = (reg_addr == REG_CTRL) ? ctrl : 8'h00;

// Header: only GPIO26 is ours (FPGA_OUT); the shell ignores the other bits.
assign hdr_out = {10{1'b0}} | ({9'b0, ctrl[0]} << `FW2_SIG_GPIO26);
assign hdr_oe  = 10'b0 | (10'b1 << `FW2_SIG_GPIO26);

// Unused ports: tie off (keeps verilator -Wall clean)
assign rp_out        = 10'b0;
assign fifo_tx_ready = 1'b0;
assign fifo_rx_data  = 8'h00;
assign fifo_rx_valid = 1'b0;

/* verilator lint_off UNUSEDSIGNAL */
wire unused = &{1'b0, hdr_in, rp_in, reg_rd, fifo_tx_data, fifo_tx_valid, fifo_rx_ready};
/* verilator lint_on UNUSEDSIGNAL */

endmodule
