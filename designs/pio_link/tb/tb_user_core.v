// pio_link unit test: the counter advances once per link-clock period, data is
// stable on the rising edge of the link clock, and the bit mapping is as documented.
`timescale 1ns/1ps
module tb_user_core;
    reg clk = 0; always #16 clk = ~clk;   // 31.25 MHz
    reg rst_n = 0;
    wire [9:0] hdr_out, hdr_oe, rp_out;
    reg  [6:0] reg_addr = 0; reg [7:0] reg_wdata = 0; reg reg_wr = 0, reg_rd = 0;
    wire [7:0] reg_rdata; wire fifo_tx_ready, fifo_rx_valid; wire [7:0] fifo_rx_data;

    user_core dut(.clk(clk), .rst_n(rst_n), .hdr_in(10'd0), .hdr_out(hdr_out), .hdr_oe(hdr_oe),
                  .rp_in(10'd0), .rp_out(rp_out), .reg_addr(reg_addr), .reg_wdata(reg_wdata),
                  .reg_wr(reg_wr), .reg_rd(reg_rd), .reg_rdata(reg_rdata),
                  .fifo_tx_data(8'd0), .fifo_tx_valid(1'b0), .fifo_tx_ready(fifo_tx_ready),
                  .fifo_rx_data(fifo_rx_data), .fifo_rx_valid(fifo_rx_valid), .fifo_rx_ready(1'b1));

    wire lclk = rp_out[8];
    wire [7:0] byte_on_bus = {rp_out[3:0], rp_out[7:4]};   // GPIO15..12 -> bits 7..4, GPIO11..8 -> bits 3..0
    integer n = 0, errors = 0;
    reg [7:0] last = 8'hFF;
    reg checking = 1'b1;

    always @(posedge lclk) begin
        // sample on the rising edge like the PIO does
        if (checking && n > 0 && byte_on_bus !== (last + 8'd1)) begin
            $display("FAIL: sample %0d = %02x, expected %02x", n, byte_on_bus, last + 8'd1); errors = errors + 1;
        end
        last = byte_on_bus; n = n + 1;
    end

    initial begin
        repeat (3) @(posedge clk); rst_n = 1;
        repeat (600) @(posedge clk);
        if (n < 250) begin $display("FAIL: only %0d link clocks in 600 clk (expected ~300)", n); errors = errors + 1; end
        // hold (stimulus changes on the falling edge so the DUT samples it cleanly)
        checking = 1'b0;
        @(negedge clk); reg_addr = 7'h10; reg_wdata = 8'h03; reg_wr = 1; @(negedge clk); reg_wr = 0;
        repeat (20) @(posedge clk);
        begin : hold_check
            reg [7:0] a; a = dut.cnt; repeat (20) @(posedge clk);
            if (dut.cnt !== a) begin $display("FAIL: counter moved while held"); errors = errors + 1; end
        end
        if (hdr_oe !== 10'd0 || fifo_rx_valid !== 1'b0) begin $display("FAIL: unused outputs not idle"); errors = errors + 1; end
        if (errors) $fatal(1, "pio_link tb: %0d errors", errors);
        $display("pio_link tb PASS: %0d link clocks, counter sequence consecutive", n);
        $finish;
    end
endmodule
