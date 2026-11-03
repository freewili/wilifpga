// tb_user_core.v - unit test of the freq_counter user_core alone.
// Feeds the GPIO27 test output back into GPIO26 (the header-jumper setup), a
// 250 kHz square wave into UART_RX, checks free-running counts, the latch and
// clear strobes, the burst freeze, and the gate (GATE_CLOCKS shrunk to 10 ms).
// Run: iverilog -g2012 -I fpga/shell -I designs/freq_counter -o build/sim/tb_freq_counter.vvp
//        designs/freq_counter/tb/tb_user_core.v designs/freq_counter/user_core.v && vvp build/sim/tb_freq_counter.vvp
`timescale 1ns/1ps
`include "fw2_profile.vh"

module tb_user_core;

reg        clk = 1'b0;
reg        rst_n = 1'b0;
reg  [6:0] reg_addr = 7'h00;
reg  [7:0] reg_wdata = 8'h00;
reg        reg_wr = 1'b0;
reg        reg_rd = 1'b0;
wire [7:0] reg_rdata;
wire [9:0] hdr_out, hdr_oe, rp_out;
reg  [9:0] hdr_in = 10'b0;
wire       fifo_tx_ready, fifo_rx_valid;
wire [7:0] fifo_rx_data;
reg        rx_sq = 1'b0;
integer    v, i;
reg  [7:0] b0, b1, b2;

always #16 clk = ~clk;                 // 31.25 MHz
always #2000 rx_sq = ~rx_sq;           // 250 kHz on UART_RX

// Header jumper 27 -> 26, square wave on UART_RX, CTS idle
always @(*) begin
  hdr_in = 10'b0;
  hdr_in[`FW2_SIG_GPIO26]  = hdr_out[`FW2_SIG_GPIO27];
  hdr_in[`FW2_SIG_UART_RX] = rx_sq;
end

user_core #(.GATE_CLOCKS(25'd312_500)) dut (   // 10 ms gate in simulation (1 s on hardware)
  .clk(clk), .rst_n(rst_n),
  .hdr_in(hdr_in), .hdr_out(hdr_out), .hdr_oe(hdr_oe),
  .rp_in(10'b0), .rp_out(rp_out),
  .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_wr(reg_wr), .reg_rd(reg_rd), .reg_rdata(reg_rdata),
  .fifo_tx_data(8'h00), .fifo_tx_valid(1'b0), .fifo_tx_ready(fifo_tx_ready),
  .fifo_rx_data(fifo_rx_data), .fifo_rx_valid(fifo_rx_valid), .fifo_rx_ready(1'b0)
);

task write_reg(input [6:0] a, input [7:0] d);
begin
  @(negedge clk); reg_addr = a; reg_wdata = d; reg_wr = 1'b1;
  @(negedge clk); reg_wr = 1'b0;
end
endtask

// Host-like read: sample rdata, then the reg_rd strobe (as the shell does)
task read_reg(input [6:0] a, output [7:0] d);
begin
  @(negedge clk); reg_addr = a; #1 d = reg_rdata;
  reg_rd = 1'b1; @(negedge clk); reg_rd = 1'b0;
  repeat (4) @(negedge clk);
end
endtask

task read24(input [6:0] base, output integer val);
begin
  read_reg(base, b0); read_reg(base + 7'd1, b1); read_reg(base + 7'd2, b2);
  val = {b2, b1, b0};
end
endtask

task check(input cond, input [8*64-1:0] msg);
begin
  if (!cond) begin $display("FAIL: %0s", msg); $fatal(1); end
end
endtask

initial begin
  repeat (3) @(negedge clk);
  rst_n = 1'b1;
  @(negedge clk);
  check(hdr_oe == (10'b1 << `FW2_SIG_GPIO27), "only GPIO27 output-enabled");
  // 1 kHz test output: 1 ms = 31250 clocks per period
  #2_000_000;                                   // 2 ms: ~2 edges on GPIO26, ~500 on UART_RX
  read24(7'h16, v); $display("  GPIO26 (jumper from GPIO27) after 2 ms: %0d edges", v);
  check(v >= 1 && v <= 3, "about 2 rising edges of the 1 kHz test signal in 2 ms");
  read24(7'h10, v); $display("  UART_RX 250 kHz after 2 ms: %0d edges", v);
  check(v >= 495 && v <= 505, "about 500 edges of 250 kHz in 2 ms");
  read24(7'h13, v); check(v == 0, "CTS idle counts 0");
  // Clear, then free-running latch semantics: snapshot follows live
  write_reg(7'h20, 8'h02);
  #400_000;
  read24(7'h10, v); $display("  UART_RX 0.4 ms after clear: %0d", v);
  check(v >= 97 && v <= 103, "about 100 edges in 0.4 ms after clear");
  // Burst freeze: bytes 2/3 must belong to the same snapshot as byte 1
  // (force a value that would roll the middle byte during the burst)
  write_reg(7'h20, 8'h02);
  #1_020_000;                                   // ~255 edges -> about to roll into byte 1
  read_reg(7'h10, b0); #40_000; read_reg(7'h11, b1); read_reg(7'h12, b2);
  $display("  burst read across a byte boundary: %02x %02x %02x", b2, b1, b0);
  check({b2, b1, b0} < 24'd300, "frozen snapshot: bytes consistent (no 0x1xx jump)");
  // Gate mode with the 10 ms simulation gate: 1 kHz -> 10 edges, 250 kHz -> 2500
  write_reg(7'h21, 8'h01);
  #10_500_000;                                  // 10.5 ms: one gate completed
  read_reg(7'h22, b0); check(b0[0] == 1'b1, "gate result flag set after the first gate");
  read24(7'h16, v); $display("  GPIO26 gated 10 ms: %0d (1 kHz -> 10)", v);
  check(v == 10, "1 kHz test signal measured as 10 edges per 10 ms gate");
  read24(7'h10, v); $display("  UART_RX gated 10 ms: %0d (250 kHz -> 2500)", v);
  check(v == 2500, "250 kHz measured as 2500 edges per 10 ms gate");
  read_reg(7'h22, b0); check(b0[0] == 1'b0, "flag cleared by reading 0x22");
  #10_000_000;
  read24(7'h10, v); check(v == 2500, "second gate also 2500 (counters restart each gate)");
  // Back to free running: snapshot follows live again
  write_reg(7'h21, 8'h00);
  #400_000;
  read24(7'h10, v); check(v >= 97 && v <= 103, "free running after the gate: ~100 edges in 0.4 ms");
  $display("tb_user_core (freq_counter) PASS");
  $finish;
end

endmodule
