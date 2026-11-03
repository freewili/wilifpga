// user_core.v - design "hello_blink": a heartbeat on GPIO26 (FPGA_OUT).
// Register 0x10 sets the blink rate: the half period is (rate + 1) x 2^20
// clocks, so at 31.25 MHz rate = 7 gives 8 x 1048576 / 31.25e6 = 268 ms per
// half period, about 1.9 Hz (the ~2 Hz default). rate = 0 is about 15 Hz.
// Register 0x11 (read only) mirrors the current LED level in bit 0.
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

localparam [6:0] REG_RATE  = 7'h10;
localparam [6:0] REG_LEVEL = 7'h11;
localparam [7:0] RATE_DEFAULT = 8'd7;   // ~1.9 Hz from 31.25 MHz
// Prescaler: 2^20 clocks = 33.5 ms at 31.25 MHz. Kept as a constant so a
// design.toml with another clock_hz still blinks at a human rate.
localparam integer PRESCALE_BITS = 20;

reg [7:0]  rate  = RATE_DEFAULT;
reg [PRESCALE_BITS-1:0] prescale = {PRESCALE_BITS{1'b0}};
reg [7:0]  ticks = 8'd0;
reg        led   = 1'b0;

always @(posedge clk) begin
  if (!rst_n) begin
    rate     <= RATE_DEFAULT;
    prescale <= {PRESCALE_BITS{1'b0}};
    ticks    <= 8'd0;
    led      <= 1'b0;
  end else begin
    if (reg_wr && reg_addr == REG_RATE) begin
      rate <= reg_wdata;
    end
    prescale <= prescale + {{(PRESCALE_BITS-1){1'b0}}, 1'b1};
    if (&prescale) begin                 // one tick every 2^PRESCALE_BITS clocks
      if (ticks >= rate) begin
        ticks <= 8'd0;
        led   <= ~led;
      end else begin
        ticks <= ticks + 8'd1;
      end
    end
  end
end

always @(*) begin
  case (reg_addr)
    REG_RATE:  reg_rdata = rate;
    REG_LEVEL: reg_rdata = {7'b0, led};
    default:   reg_rdata = 8'h00;
  endcase
end

assign hdr_out = {9'b0, led} << `FW2_SIG_GPIO26;
assign hdr_oe  = 10'b1 << `FW2_SIG_GPIO26;

assign rp_out        = 10'b0;
assign fifo_tx_ready = 1'b0;
assign fifo_rx_data  = 8'h00;
assign fifo_rx_valid = 1'b0;

/* verilator lint_off UNUSEDSIGNAL */
wire unused = &{1'b0, hdr_in, rp_in, reg_rd, fifo_tx_data, fifo_tx_valid, fifo_rx_ready};
/* verilator lint_on UNUSEDSIGNAL */

endmodule
