// pio_sink unit test: a model of the RP2350 PIO drives bytes and the link
// clock (data changes while the clock is low, the FPGA takes it on the rise),
// including stalls with the clock low. The core must count every byte and see
// no errors; a deliberately skipped value must count exactly one error.
`timescale 1ns/1ps
module tb_user_core;
    reg clk = 0; always #16 clk = ~clk;   // 31.25 MHz fabric clock
    reg rst_n = 0;
    reg lclk = 0;
    reg [7:0] b = 8'h00;
    wire [9:0] hdr_out, hdr_oe, rp_out;
    reg  [6:0] reg_addr = 0; reg [7:0] reg_wdata = 0; reg reg_wr = 0;
    wire [7:0] reg_rdata; wire fifo_tx_ready, fifo_rx_valid; wire [7:0] fifo_rx_data;

    // bits 0..3 on signals 4..7, bits 4..7 on signals 0..3, clock on signal 8
    wire [9:0] rp_in = {1'b0, lclk, b[3:0], b[7:4]};
    user_core dut(.clk(clk), .rst_n(rst_n), .hdr_in(10'd0), .hdr_out(hdr_out), .hdr_oe(hdr_oe),
                  .rp_in(rp_in), .rp_out(rp_out), .reg_addr(reg_addr), .reg_wdata(reg_wdata),
                  .reg_wr(reg_wr), .reg_rd(1'b0), .reg_rdata(reg_rdata),
                  .fifo_tx_data(8'd0), .fifo_tx_valid(1'b0), .fifo_tx_ready(fifo_tx_ready),
                  .fifo_rx_data(fifo_rx_data), .fifo_rx_valid(fifo_rx_valid), .fifo_rx_ready(1'b1));

    integer errors = 0;
    task send(input [7:0] v, input integer lo_ns, input integer hi_ns);
        begin
            lclk = 0; b = v; #(lo_ns);
            lclk = 1; #(hi_ns);
        end
    endtask
    task rd32(input [6:0] a, output [31:0] v);
        begin
            reg_addr = a;     #1 v[7:0]   = reg_rdata;
            reg_addr = a + 1; #1 v[15:8]  = reg_rdata;
            reg_addr = a + 2; #1 v[23:16] = reg_rdata;
            reg_addr = a + 3; #1 v[31:24] = reg_rdata;
        end
    endtask
    task clear;
        begin
            @(negedge clk); reg_addr = 7'h10; reg_wdata = 8'h01; reg_wr = 1; @(negedge clk); reg_wr = 0;
        end
    endtask

    integer i;
    reg [31:0] c, e;
    initial begin
        repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);
        clear;
        // clkdiv 2 timing (160 ns low, 213 ns high), 500 bytes from 0x37 with a 20 us stall
        for (i = 0; i < 250; i = i + 1) send(8'h37 + i[7:0], 160, 213);
        lclk = 0; #20000;
        for (i = 250; i < 500; i = i + 1) send(8'h37 + i[7:0], 160, 213);
        // clkdiv 1 timing (80 ns low, 107 ns high), 500 more
        for (i = 500; i < 1000; i = i + 1) send(8'h37 + i[7:0], 80, 107);
        lclk = 0; repeat (6) @(posedge clk);
        rd32(7'h11, c); rd32(7'h15, e);
        if (c !== 32'd1000) begin $display("FAIL: count %0d, expected 1000", c); errors = errors + 1; end
        if (e !== 32'd0)    begin $display("FAIL: %0d pattern errors on a clean stream", e); errors = errors + 1; end
        reg_addr = 7'h1A; #1 if (reg_rdata !== 8'h37) begin $display("FAIL: first byte %02x", reg_rdata); errors = errors + 1; end
        // a skipped value must be exactly one error
        clear;
        send(8'h10, 160, 213); send(8'h11, 160, 213); send(8'h13, 160, 213); send(8'h14, 160, 213);
        lclk = 0; repeat (6) @(posedge clk);
        rd32(7'h11, c); rd32(7'h15, e);
        if (c !== 32'd4 || e !== 32'd1) begin $display("FAIL: skip test count %0d errors %0d", c, e); errors = errors + 1; end
        if (rp_out !== 10'd0 || hdr_oe !== 10'd0) begin $display("FAIL: outputs outside the profile"); errors = errors + 1; end
        if (errors) $fatal(1, "pio_sink tb: %0d errors", errors);
        $display("pio_sink tb PASS: 1000 bytes counted with 0 errors across a stall; a skip counts 1");
        $finish;
    end
endmodule
