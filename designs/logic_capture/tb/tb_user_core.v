// tb_user_core.v - unit test of the logic_capture user_core alone, with a
// small FIFO model on the fifo_rx port. Checks divider timing, sample packing,
// trigger modes, one-shot completion on a full FIFO and the dropped flag.
// Run: iverilog -g2012 -I fpga/shell -I designs/logic_capture -o build/sim/tb_logic_capture.vvp
//        designs/logic_capture/tb/tb_user_core.v designs/logic_capture/user_core.v && vvp build/sim/tb_logic_capture.vvp
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
reg  [9:0] hdr_in = 10'b0;
wire       fifo_tx_ready, fifo_rx_valid;
wire [7:0] fifo_rx_data;
reg  [7:0] cap [0:65535];
integer    ncap = 0, i, t0, t1;
reg        fifo_en = 1'b1;          // FIFO model: ready = not full (64 entries in the one-shot test)
integer    fifo_limit = 1 << 20;
wire       fifo_rx_ready = fifo_en && (ncap < fifo_limit);
reg  [7:0] d;

always #16 clk = ~clk;

user_core dut (
  .clk(clk), .rst_n(rst_n),
  .hdr_in(hdr_in), .hdr_out(hdr_out), .hdr_oe(hdr_oe),
  .rp_in(10'b0), .rp_out(rp_out),
  .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_wr(reg_wr), .reg_rd(1'b0), .reg_rdata(reg_rdata),
  .fifo_tx_data(8'h00), .fifo_tx_valid(1'b0), .fifo_tx_ready(fifo_tx_ready),
  .fifo_rx_data(fifo_rx_data), .fifo_rx_valid(fifo_rx_valid), .fifo_rx_ready(fifo_rx_ready)
);

// FIFO model: accept while ready
always @(posedge clk) if (fifo_rx_valid && fifo_rx_ready) begin cap[ncap] <= fifo_rx_data; ncap <= ncap + 1; end

task write_reg(input [6:0] a, input [7:0] v);
begin
  @(negedge clk); reg_addr = a; reg_wdata = v; reg_wr = 1'b1;
  @(negedge clk); reg_wr = 1'b0;
end
endtask

task read_reg(input [6:0] a, output [7:0] v);
begin
  @(negedge clk); reg_addr = a; #1 v = reg_rdata;
end
endtask

task check(input cond, input [8*64-1:0] msg);
begin
  if (!cond) begin $display("FAIL: %0s", msg); $fatal(1); end
end
endtask

// input pattern: an 8-bit counter advancing every 8 clocks
reg [7:0] pat = 8'h00;
reg [2:0] pat_div = 3'd0;
always @(posedge clk) begin
  pat_div <= pat_div + 3'd1;
  if (pat_div == 3'd7) pat <= pat + 8'd1;
  hdr_in[7:0] <= pat;
end

initial begin
  repeat (3) @(negedge clk);
  rst_n = 1'b1;
  @(negedge clk);
  check(hdr_oe == 10'b0, "no outputs");
  read_reg(7'h13, d); check(d == 8'h00, "idle status");
  // Continuous run, divider 7 (one sample every 8 clocks = one per pattern value)
  write_reg(7'h10, 8'd7);
  ncap = 0;
  write_reg(7'h11, 8'h01);
  repeat (8 * 100 + 20) @(posedge clk);
  write_reg(7'h11, 8'h00);
  $display("  continuous div 7: %0d samples captured", ncap);
  check(ncap >= 99 && ncap <= 102, "about 100 samples in 800 clocks at div 7");
  for (i = 1; i < ncap; i = i + 1)
    if (cap[i] != cap[i-1] + 8'd1) begin $display("FAIL: sample %0d = %02x after %02x", i, cap[i], cap[i-1]); $fatal(1); end
  // One-shot with the FIFO model refusing after 64 samples
  ncap = 0;
  write_reg(7'h10, 8'd0);
  fifo_limit = 64;
  write_reg(7'h11, 8'h03);
  repeat (200) @(posedge clk);
  read_reg(7'h13, d);
  $display("  one-shot: %0d samples, status %02x", ncap, d);
  check(d[2] == 1'b1 && d[0] == 1'b0, "one-shot done, run cleared when the FIFO filled");
  check(ncap == 64, "exactly 64 samples accepted, none lost or extra");
  fifo_limit = 1 << 20;
  // Trigger: wait for rising edge on GPIO26
  hdr_in[`FW2_SIG_GPIO26] = 1'b0;
  ncap = 0;
  write_reg(7'h12, 8'h01);
  write_reg(7'h11, 8'h05);          // run + wait for trigger
  repeat (200) @(posedge clk);
  read_reg(7'h13, d);
  check(ncap == 0 && d[1] == 1'b0, "nothing captured before the trigger");
  @(negedge clk); hdr_in[`FW2_SIG_GPIO26] = 1'b1;
  repeat (50) @(posedge clk);
  read_reg(7'h13, d);
  check(d[1] == 1'b1 && ncap > 40, "capturing after the rising edge");
  write_reg(7'h11, 8'h00);
  // Falling-edge trigger must ignore a rising edge
  hdr_in[`FW2_SIG_GPIO26] = 1'b0; ncap = 0;
  write_reg(7'h12, 8'h02);
  write_reg(7'h11, 8'h05);
  @(negedge clk); hdr_in[`FW2_SIG_GPIO26] = 1'b1;
  repeat (50) @(posedge clk);
  check(ncap == 0, "falling-edge trigger ignores a rising edge");
  @(negedge clk); hdr_in[`FW2_SIG_GPIO26] = 1'b0;
  repeat (50) @(posedge clk);
  check(ncap > 40, "falling edge triggers");
  // Dropped flag in continuous mode when the FIFO is full
  fifo_en = 1'b0;
  repeat (20) @(posedge clk);
  read_reg(7'h13, d);
  check(d[3] == 1'b1, "dropped flag set when running continuously into a full FIFO");
  fifo_en = 1'b1;
  write_reg(7'h11, 8'h00);
  read_reg(7'h14, d);
  check(d == dut.in_s1, "live input byte readable");
  $display("tb_user_core (logic_capture) PASS");
  $finish;
end

endmodule
