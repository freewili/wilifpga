// pio_stream unit test: a model of the RP2350 PIO drives the link clock and
// samples the byte at each falling edge; it also pauses the clock for long
// stretches (back-pressure). Every sample must be the previous one + 1 and the
// counter must not move while the clock is stopped.
`timescale 1ns/1ps
module tb_user_core;
    reg clk = 0; always #16 clk = ~clk;   // 31.25 MHz fabric clock
    reg rst_n = 0;
    reg lclk = 0;
    wire [9:0] hdr_out, hdr_oe, rp_out;
    reg  [6:0] reg_addr = 0; reg [7:0] reg_wdata = 0; reg reg_wr = 0;
    wire [7:0] reg_rdata; wire fifo_tx_ready, fifo_rx_valid; wire [7:0] fifo_rx_data;

    user_core dut(.clk(clk), .rst_n(rst_n), .hdr_in(10'd0), .hdr_out(hdr_out), .hdr_oe(hdr_oe),
                  .rp_in({1'b0, lclk, 8'd0}), .rp_out(rp_out), .reg_addr(reg_addr), .reg_wdata(reg_wdata),
                  .reg_wr(reg_wr), .reg_rd(1'b0), .reg_rdata(reg_rdata),
                  .fifo_tx_data(8'd0), .fifo_tx_valid(1'b0), .fifo_tx_ready(fifo_tx_ready),
                  .fifo_rx_data(fifo_rx_data), .fifo_rx_valid(fifo_rx_valid), .fifo_rx_ready(1'b1));

    wire [7:0] bus = {rp_out[3:0], rp_out[7:4]};
    integer errors = 0, n = 0;
    reg [7:0] last;

    // One PIO link period: high for HI ns, then drive low and sample in the same instant.
    task pio_cycle(input integer hi_ns, input integer lo_ns);
        begin
            lclk = 1; #(hi_ns);
            lclk = 0;
            if (n > 0 && bus !== last + 8'd1) begin
                $display("FAIL: sample %0d = %02x, expected %02x", n, bus, last + 8'd1); errors = errors + 1;
            end
            last = bus; n = n + 1;
            #(lo_ns);
        end
    endtask

    integer i;
    reg [7:0] held;
    initial begin
        repeat (4) @(posedge clk); rst_n = 1;
        repeat (4) @(posedge clk);
        // the slowest sensible timing (PIO clkdiv 2: 213 ns high, 160 ns low)
        for (i = 0; i < 300; i = i + 1) pio_cycle(213, 160);
        // back-pressure: clock stopped low for 20 us; the counter must hold
        held = bus; #20000;
        if (bus !== held) begin $display("FAIL: counter moved while the clock was stopped"); errors = errors + 1; end
        // resume and continue checking across the pause
        for (i = 0; i < 300; i = i + 1) pio_cycle(213, 160);
        // the fastest timing the firmware offers (clkdiv 1: 107 ns high, 80 ns low)
        for (i = 0; i < 600; i = i + 1) pio_cycle(107, 80);
        if (hdr_oe !== 10'd0 || rp_out[9:8] !== 2'b00) begin $display("FAIL: outputs outside the profile"); errors = errors + 1; end
        if (errors) $fatal(1, "pio_stream tb: %0d errors", errors);
        $display("pio_stream tb PASS: %0d samples consecutive across a 20 us pause", n);
        $finish;
    end
endmodule
