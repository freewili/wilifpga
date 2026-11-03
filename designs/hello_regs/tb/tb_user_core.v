// tb_user_core.v - unit test of the hello_regs user_core alone.
// Run: iverilog -g2012 -I fpga/shell -I designs/hello_regs -o build/sim/tb_hello_regs.vvp
//        designs/hello_regs/tb/tb_user_core.v designs/hello_regs/user_core.v && vvp build/sim/tb_hello_regs.vvp
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
wire       fifo_tx_ready, fifo_rx_valid;
wire [7:0] fifo_rx_data;
integer    i;
reg  [7:0] x;

always #16 clk = ~clk;

user_core dut (
  .clk(clk), .rst_n(rst_n),
  .hdr_in(10'b0), .hdr_out(hdr_out), .hdr_oe(hdr_oe),
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

task read_reg(input [6:0] a, output [7:0] d);
begin
  @(negedge clk); reg_addr = a; #1 d = reg_rdata;
  reg_rd = 1'b1; @(negedge clk); reg_rd = 1'b0;
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
  check(hdr_oe == ((10'b1 << `FW2_SIG_GPIO26) | (10'b1 << `FW2_SIG_GPIO27)), "GPIO26 and GPIO27 output-enabled");
  for (i = 0; i < 8; i = i + 1) write_reg(7'h10 + i[6:0], 8'h30 + i[7:0]);
  for (i = 0; i < 8; i = i + 1) begin
    read_reg(7'h10 + i[6:0], x);
    check(x == 8'h30 + i[7:0], "register round trip 0x10-0x17");
  end
  read_reg(7'h18, x); check(x == 8'd8, "write counter = 8");
  read_reg(7'h19, x); check(x == 8'd1, "read counter counts reads of 0x17");
  read_reg(7'h1A, x);
  check(x == (8'h30 ^ 8'h31 ^ 8'h32 ^ 8'h33 ^ 8'h34 ^ 8'h35 ^ 8'h36 ^ 8'h37), "XOR of the window");
  write_reg(7'h10, 8'h01);
  check(hdr_out[`FW2_SIG_GPIO26] == 1'b1 && hdr_out[`FW2_SIG_GPIO27] == 1'b0, "GPIO26 = bit0");
  write_reg(7'h10, 8'h02);
  check(hdr_out[`FW2_SIG_GPIO26] == 1'b0 && hdr_out[`FW2_SIG_GPIO27] == 1'b1, "GPIO27 = bit1");
  write_reg(7'h20, 8'hAA);   // outside the window
  read_reg(7'h20, x); check(x == 8'h00, "0x20 unimplemented reads 0");
  read_reg(7'h18, x); check(x == 8'd10, "writes outside the window not counted (10 = 8 + 2)");
  $display("tb_user_core (hello_regs) PASS");
  $finish;
end

endmodule
