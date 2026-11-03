// user_core.v - design "hello_regs": eight read/write registers 0x10-0x17.
// GPIO26 mirrors bit 0 and GPIO27 mirrors bit 1 of register 0x10 (both
// FPGA_OUT). Register 0x18 (read only) counts writes to the window, 0x19
// (read only) counts reads of 0x17 (shows the reg_rd strobe), 0x1A returns
// the XOR of the eight registers.
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
  output reg  [7:0] reg_rdata,
  input  wire [7:0] fifo_tx_data,
  input  wire       fifo_tx_valid,
  output wire       fifo_tx_ready,
  output wire [7:0] fifo_rx_data,
  output wire       fifo_rx_valid,
  input  wire       fifo_rx_ready
);

localparam [6:0] REG_BASE   = 7'h10;   // 0x10..0x17
localparam [6:0] REG_WRCNT  = 7'h18;
localparam [6:0] REG_RDCNT  = 7'h19;
localparam [6:0] REG_XOR    = 7'h1A;

reg [7:0] regs [0:7];
reg [7:0] wr_count = 8'd0;
reg [7:0] rd_count = 8'd0;
wire      in_regs = (reg_addr[6:3] == REG_BASE[6:3]);   // 0x10-0x17
integer   i;

always @(posedge clk) begin
  if (!rst_n) begin
    for (i = 0; i < 8; i = i + 1) regs[i] <= 8'h00;
    wr_count <= 8'd0;
    rd_count <= 8'd0;
  end else begin
    if (reg_wr && in_regs) begin
      regs[reg_addr[2:0]] <= reg_wdata;
      wr_count <= wr_count + 8'd1;
    end
    if (reg_rd && reg_addr == (REG_BASE + 7'd7)) begin
      rd_count <= rd_count + 8'd1;
    end
  end
end

wire [7:0] xor_all = regs[0] ^ regs[1] ^ regs[2] ^ regs[3] ^ regs[4] ^ regs[5] ^ regs[6] ^ regs[7];

always @(*) begin
  if (in_regs)                    reg_rdata = regs[reg_addr[2:0]];
  else if (reg_addr == REG_WRCNT) reg_rdata = wr_count;
  else if (reg_addr == REG_RDCNT) reg_rdata = rd_count;
  else if (reg_addr == REG_XOR)   reg_rdata = xor_all;
  else                            reg_rdata = 8'h00;
end

assign hdr_out = ({9'b0, regs[0][0]} << `FW2_SIG_GPIO26) | ({9'b0, regs[0][1]} << `FW2_SIG_GPIO27);
assign hdr_oe  = (10'b1 << `FW2_SIG_GPIO26) | (10'b1 << `FW2_SIG_GPIO27);

assign rp_out        = 10'b0;
assign fifo_tx_ready = 1'b0;
assign fifo_rx_data  = 8'h00;
assign fifo_rx_valid = 1'b0;

/* verilator lint_off UNUSEDSIGNAL */
wire unused = &{1'b0, hdr_in, rp_in, fifo_tx_data, fifo_tx_valid, fifo_rx_ready};
/* verilator lint_on UNUSEDSIGNAL */

endmodule
