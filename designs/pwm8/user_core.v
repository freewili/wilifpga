// user_core.v - design "pwm8": eight PWM channels on the eight shifter-driven
// header signals (spi_miso, spi_cs, spi_sclk, spi_mosi, uart_tx, uart_rx,
// uart_cts, uart_rts = FW2_SIG 0..7), all FPGA_OUT. GPIO26/27 stay passthrough.
//
// PWM period = 256 x (prescale + 1) clocks. Default prescale 121 gives
// 31.25 MHz / (256 x 122) = 1000.3 Hz. Duty = value / 256 (0 = off, 0x80 = 50 %,
// 0xFF = 99.6 %). Channels start disabled with duty 0 so every header LED is off
// until the host writes it.
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

localparam [6:0] REG_DUTY0    = 7'h10;   // 0x10..0x17
localparam [6:0] REG_PRESCALE = 7'h18;
localparam [6:0] REG_ENABLE   = 7'h19;
localparam [6:0] REG_PHASE    = 7'h1A;   // RO: current PWM counter
localparam [7:0] PRESCALE_1KHZ = 8'd121;

reg [7:0] duty [0:7];
reg [7:0] prescale = PRESCALE_1KHZ;
reg [7:0] enable   = 8'h00;
reg [7:0] pre_cnt  = 8'd0;
reg [7:0] phase    = 8'd0;
reg [7:0] pwm      = 8'h00;
wire      in_duty  = (reg_addr[6:3] == REG_DUTY0[6:3]);   // 0x10-0x17
integer   i;

always @(posedge clk) begin
  if (!rst_n) begin
    for (i = 0; i < 8; i = i + 1) duty[i] <= 8'h00;
    prescale <= PRESCALE_1KHZ;
    enable   <= 8'h00;
    pre_cnt  <= 8'd0;
    phase    <= 8'd0;
    pwm      <= 8'h00;
  end else begin
    if (reg_wr) begin
      if (in_duty)                        duty[reg_addr[2:0]] <= reg_wdata;
      else if (reg_addr == REG_PRESCALE)  prescale <= reg_wdata;
      else if (reg_addr == REG_ENABLE)    enable   <= reg_wdata;
    end
    // Prescaled 8-bit phase counter
    if (pre_cnt == prescale) begin
      pre_cnt <= 8'd0;
      phase   <= phase + 8'd1;
    end else begin
      pre_cnt <= pre_cnt + 8'd1;
    end
    // Registered compare: high while phase < duty (duty 0 -> always low)
    for (i = 0; i < 8; i = i + 1) pwm[i] <= enable[i] & (phase < duty[i]);
  end
end

always @(*) begin
  if (in_duty)                      reg_rdata = duty[reg_addr[2:0]];
  else if (reg_addr == REG_PRESCALE) reg_rdata = prescale;
  else if (reg_addr == REG_ENABLE)   reg_rdata = enable;
  else if (reg_addr == REG_PHASE)    reg_rdata = phase;
  else                               reg_rdata = 8'h00;
end

assign hdr_out = {2'b00, pwm};
assign hdr_oe  = {2'b00, 8'hFF};

assign rp_out        = 10'b0;
assign fifo_tx_ready = 1'b0;
assign fifo_rx_data  = 8'h00;
assign fifo_rx_valid = 1'b0;

/* verilator lint_off UNUSEDSIGNAL */
wire unused = &{1'b0, hdr_in, rp_in, reg_rd, fifo_tx_data, fifo_tx_valid, fifo_rx_ready};
/* verilator lint_on UNUSEDSIGNAL */

endmodule
