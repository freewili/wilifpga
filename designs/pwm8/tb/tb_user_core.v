// tb_user_core.v - unit test of the pwm8 user_core alone.
// Checks defaults (all off), the 1 kHz default period, duty cycle on two
// channels and the enable mask.
// Run: iverilog -g2012 -I fpga/shell -I designs/pwm8 -o build/sim/tb_pwm8.vvp
//        designs/pwm8/tb/tb_user_core.v designs/pwm8/user_core.v && vvp build/sim/tb_pwm8.vvp
`timescale 1ns/1ps
`include "fw2_profile.vh"

module tb_user_core;

reg        clk = 1'b0;
reg        rst_n = 1'b0;
reg  [6:0] reg_addr = 7'h00;
reg  [7:0] reg_wdata = 8'h00;
reg        reg_wr = 1'b0;
wire [7:0] reg_rdata;
wire [9:0] hdr_out, hdr_oe, rp_out;
wire       fifo_tx_ready, fifo_rx_valid;
wire [7:0] fifo_rx_data;
integer    n, high, period;
reg        prev;

always #16 clk = ~clk;   // 31.25 MHz

user_core dut (
  .clk(clk), .rst_n(rst_n),
  .hdr_in(10'b0), .hdr_out(hdr_out), .hdr_oe(hdr_oe),
  .rp_in(10'b0), .rp_out(rp_out),
  .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_wr(reg_wr), .reg_rd(1'b0), .reg_rdata(reg_rdata),
  .fifo_tx_data(8'h00), .fifo_tx_valid(1'b0), .fifo_tx_ready(fifo_tx_ready),
  .fifo_rx_data(fifo_rx_data), .fifo_rx_valid(fifo_rx_valid), .fifo_rx_ready(1'b0)
);

task write_reg(input [6:0] a, input [7:0] d);
begin
  @(negedge clk); reg_addr = a; reg_wdata = d; reg_wr = 1'b1;
  @(negedge clk); reg_wr = 1'b0;
end
endtask

task check(input cond, input [8*64-1:0] msg);
begin
  if (!cond) begin $display("FAIL: %0s", msg); $fatal(1); end
end
endtask

// Measure one full period of channel ch: clocks high and total clocks
task measure(input integer ch, output integer hi, output integer per);
begin
  // Skip the first high phase, which may be partial (enable written mid-phase)
  @(posedge clk); while (hdr_out[ch] == 1'b1) @(posedge clk);
  while (hdr_out[ch] == 1'b0) @(posedge clk);
  while (hdr_out[ch] == 1'b1) @(posedge clk);
  while (hdr_out[ch] == 1'b0) @(posedge clk);                    // rising edge of a full period
  hi = 0; per = 0;
  while (hdr_out[ch] == 1'b1) begin @(posedge clk); hi = hi + 1; per = per + 1; end
  while (hdr_out[ch] == 1'b0) begin @(posedge clk); per = per + 1; end
end
endtask

initial begin
  repeat (3) @(negedge clk);
  rst_n = 1'b1;
  @(negedge clk);
  check(hdr_oe == 10'h0FF, "channels 0-7 output-enabled, GPIO26/27 not");
  reg_addr = 7'h18; @(negedge clk); check(reg_rdata == 8'd121, "default prescale 121 (1 kHz)");
  reg_addr = 7'h19; @(negedge clk); check(reg_rdata == 8'h00, "default enable mask 0");
  repeat (70000) @(posedge clk);
  check(hdr_out[7:0] == 8'h00, "all channels low with duty 0 / disabled");
  // duty 0x80 on channel 2 but not enabled -> still low
  write_reg(7'h12, 8'h80);
  repeat (70000) @(posedge clk);
  check(hdr_out[2] == 1'b0, "channel stays low until enabled");
  write_reg(7'h19, 8'h04);
  measure(2, high, period);
  $display("  ch2 duty 0x80: high %0d / period %0d clocks (expect 15616 / 31232 = 1000.3 Hz)", high, period);
  check(period == 256 * 122, "period = 256 x (prescale+1) clocks");
  check(high == 128 * 122, "50 % duty");
  // channel 5 duty 0x40 with prescale 0 (fast)
  write_reg(7'h18, 8'd0);
  write_reg(7'h15, 8'h40);
  write_reg(7'h19, 8'h24);
  measure(5, high, period);
  $display("  ch5 duty 0x40 prescale 0: high %0d / period %0d", high, period);
  check(period == 256 && high == 64, "25 % duty at prescale 0");
  check(hdr_out[0] == 1'b0 && hdr_out[1] == 1'b0, "other channels stay low");
  reg_addr = 7'h15; @(negedge clk); check(reg_rdata == 8'h40, "duty register reads back");
  $display("tb_user_core (pwm8) PASS");
  $finish;
end

endmodule
