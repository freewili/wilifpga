// tb_user_core.v - unit test of the hello_blink user_core alone.
// Checks the default rate, that GPIO26 toggles with the expected half period
// ((rate+1) x 2^20 clocks) and that register 0x10 changes it.
// Run: iverilog -g2012 -I fpga/shell -I designs/hello_blink -o build/sim/tb_hello_blink.vvp
//        designs/hello_blink/tb/tb_user_core.v designs/hello_blink/user_core.v && vvp build/sim/tb_hello_blink.vvp
`timescale 1ns/1ps
`include "fw2_profile.vh"

module tb_user_core;

localparam integer PRESCALE = 1 << 20;

reg        clk = 1'b0;
reg        rst_n = 1'b0;
reg  [6:0] reg_addr = 7'h00;
reg  [7:0] reg_wdata = 8'h00;
reg        reg_wr = 1'b0;
wire [7:0] reg_rdata;
wire [9:0] hdr_out, hdr_oe, rp_out;
wire       fifo_tx_ready, fifo_rx_valid;
wire [7:0] fifo_rx_data;
integer    cycles, edges;
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

wire led = hdr_out[`FW2_SIG_GPIO26];

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

// Count clocks between two consecutive LED toggles
task measure_half_period(output integer n);
begin
  @(posedge clk); prev = led;
  while (led == prev) @(posedge clk);
  prev = led; n = 0;
  while (led == prev) begin @(posedge clk); n = n + 1; end
end
endtask

initial begin
  repeat (3) @(negedge clk);
  rst_n = 1'b1;
  @(negedge clk);
  check(hdr_oe == (10'b1 << `FW2_SIG_GPIO26), "only GPIO26 output-enabled");
  reg_addr = 7'h10; @(negedge clk);
  check(reg_rdata == 8'd7, "default rate register is 7 (~1.9 Hz)");
  // rate 0: half period = 1 x 2^20 clocks
  write_reg(7'h10, 8'h00);
  measure_half_period(cycles);
  $display("  rate 0: half period %0d clocks (expect %0d)", cycles, PRESCALE);
  check(cycles == PRESCALE, "rate 0 half period = 2^20 clocks");
  // rate 2: half period = 3 x 2^20 clocks
  write_reg(7'h10, 8'h02);
  measure_half_period(cycles);   // first interval may straddle the change
  measure_half_period(cycles);
  $display("  rate 2: half period %0d clocks (expect %0d)", cycles, 3*PRESCALE);
  check(cycles == 3*PRESCALE, "rate 2 half period = 3 x 2^20 clocks");
  reg_addr = 7'h11; @(negedge clk);
  check(reg_rdata[0] == led, "register 0x11 mirrors the LED level");
  $display("tb_user_core (hello_blink) PASS: default rate 7 -> %0.2f Hz at 31.25 MHz",
           31.25e6 / (2.0 * 8.0 * PRESCALE));
  $finish;
end

endmodule
