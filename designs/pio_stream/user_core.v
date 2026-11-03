// pio_stream - continuous, lossless FPGA -> RP2350 stream with RP2350-driven
// link clock (back-pressure for free).
//
// The RP2350's PIO drives the link clock on GPIO26. It samples GPIO8-15 at the
// instant it drives the clock low, and it stops clocking whenever its RX FIFO
// is full (its DMA buffer is being written to the SD card), so this core never
// produces a byte the host cannot take. The core oversamples the clock with
// its own 31.25 MHz clock: a 2-flop synchroniser plus an edge detector, and on
// every falling edge it advances the counter. The RP2350 therefore always
// samples a value that has been stable for most of a link period.
//
// Byte bit k rides on the signal whose RP2350 GPIO is 8+k (same as pio_link):
//   bits 0..3 -> uart_tx(8) uart_rx(9) uart_cts(10) uart_rts(11) = signals 4..7
//   bits 4..7 -> spi_miso(12) spi_cs(13) spi_sclk(14) spi_mosi(15) = signals 0..3
//
// Registers (absolute):
//   0x10  control: bit0 run (default 1: count on every falling edge)
//                  write bit1 = 1: reset the counter and the edge count
//   0x11  current counter value (RO)
//   0x12..0x15  falling edges seen since reset, u32 LE (RO, live)
`include "fw2_user_core.vh"

module user_core (
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
    // link clock from the RP2350 (signal 8 = gpio26), synchronised
    reg [2:0] lclk_s = 3'b000;
    always @(posedge clk) lclk_s <= {lclk_s[1:0], rp_in[8]};
    wire fall = lclk_s[2] & ~lclk_s[1];

    reg        run   = 1'b1;
    reg [7:0]  cnt   = 8'h00;
    reg [31:0] edges = 32'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            run   <= 1'b1;
            cnt   <= 8'h00;
            edges <= 32'd0;
        end else begin
            if (reg_wr && reg_addr == 7'h10) run <= reg_wdata[0];
            if (reg_wr && reg_addr == 7'h10 && reg_wdata[1]) begin
                cnt   <= 8'h00;
                edges <= 32'd0;
            end else if (fall && run) begin
                cnt   <= cnt + 8'd1;
                edges <= edges + 32'd1;
            end
        end
    end

    always @(*) begin
        case (reg_addr)
            7'h10: reg_rdata = {7'd0, run};
            7'h11: reg_rdata = cnt;
            7'h12: reg_rdata = edges[7:0];
            7'h13: reg_rdata = edges[15:8];
            7'h14: reg_rdata = edges[23:16];
            7'h15: reg_rdata = edges[31:24];
            default: reg_rdata = 8'h00;
        endcase
    end

    // signals 0..3 (GPIO12..15) carry bits 4..7, signals 4..7 (GPIO8..11) carry bits 0..3;
    // signal 8 (gpio26) is an input here (LINK_RP2F), signal 9 passthrough.
    assign rp_out = {2'b00, cnt[3:0], cnt[7:4]};
    assign hdr_out = 10'd0;
    assign hdr_oe  = 10'd0;
    assign fifo_tx_ready = 1'b0;
    assign fifo_rx_data  = 8'd0;
    assign fifo_rx_valid = 1'b0;

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{1'b0, hdr_in, rp_in[7:0], rp_in[9], reg_rd, fifo_tx_data, fifo_tx_valid,
                    fifo_rx_ready, reg_wdata[7:2]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
