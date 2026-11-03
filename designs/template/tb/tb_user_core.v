// tb_user_core.v - unit test of the template user_core alone (no shell, no SPI).
// Drives the register strobes directly and checks GPIO26 follows register 0x10.
// Run: iverilog -g2012 -I fpga/shell -I designs/template -o build/sim/tb_template.vvp
//        designs/template/tb/tb_user_core.v designs/template/user_core.v && vvp build/sim/tb_template.vvp
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

task check(input cond, input [8*48-1:0] msg);
begin
  if (!cond) begin $display("FAIL: %0s", msg); $fatal(1); end
end
endtask

initial begin
  repeat (3) @(negedge clk);
  rst_n = 1'b1;
  @(negedge clk);
  check(hdr_oe == (10'b1 << `FW2_SIG_GPIO26), "only GPIO26 output-enabled");
  check(hdr_out[`FW2_SIG_GPIO26] == 1'b0, "GPIO26 low after reset");
  check(rp_out == 10'b0 && fifo_rx_valid == 1'b0 && fifo_tx_ready == 1'b0, "unused outputs tied off");
  write_reg(7'h10, 8'h01);
  check(hdr_out[`FW2_SIG_GPIO26] == 1'b1, "GPIO26 high after writing 0x10 = 1");
  reg_addr = 7'h10; @(negedge clk);
  check(reg_rdata == 8'h01, "register 0x10 reads back 1");
  reg_addr = 7'h11; @(negedge clk);
  check(reg_rdata == 8'h00, "other addresses read 0");
  write_reg(7'h11, 8'hFF);   // not ours
  check(hdr_out[`FW2_SIG_GPIO26] == 1'b1, "write to 0x11 does not affect GPIO26");
  write_reg(7'h10, 8'h00);
  check(hdr_out[`FW2_SIG_GPIO26] == 1'b0, "GPIO26 low after writing 0x10 = 0");
  $display("tb_user_core (template) PASS");
  $finish;
end

endmodule
