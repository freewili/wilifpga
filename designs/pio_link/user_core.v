// pio_link - T2 data-path demo: an 8-bit free-running counter presented on the
// inner nets of the eight shifter signals, with a link clock on GPIO26, so MAIN's
// PIO1 can capture a byte per clock with `in pins, 8` (in_base = GPIO8).
//
// Byte bit k rides on the signal whose RP2350 GPIO is 8+k:
//   bits 0..3 -> uart_tx(8) uart_rx(9) uart_cts(10) uart_rts(11) = signals 4..7
//   bits 4..7 -> spi_miso(12) spi_cs(13) spi_sclk(14) spi_mosi(15) = signals 0..3
// Data changes on the falling edge of the link clock; the RP samples on the
// rising edge, half a link period (32 ns at 15.6 MHz) later.
//
// Registers (absolute):
//   0x10  control: bit0 run (default 1), bit1 = hold (freeze the counter)
//   0x11  current counter value (RO)
//   0x12  link clock divider: 0 = clk/2 (15.6 MHz), 1 = clk/4, ... up to 7 = clk/256 (RO default 0, RW)
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
    reg [7:0] ctrl = 8'h01;
    reg [2:0] div  = 3'd0;
    reg [7:0] cnt  = 8'h00;
    reg [7:0] pre  = 8'h00;   // prescaler for the link clock
    reg       lclk = 1'b0;

    wire run  = ctrl[0] & ~ctrl[1];
    wire tick = (pre == 8'h00);

    always @(posedge clk) begin
        if (!rst_n) begin
            ctrl <= 8'h01;
            div  <= 3'd0;
            cnt  <= 8'h00;
            pre  <= 8'h00;
            lclk <= 1'b0;
        end else begin
            if (reg_wr && reg_addr == 7'h10) ctrl <= reg_wdata;
            if (reg_wr && reg_addr == 7'h12) div  <= reg_wdata[2:0];
            // prescaler: half-period = 2^div clocks
            if (tick) pre <= (8'd1 << div) - 8'd1; else pre <= pre - 8'd1;
            if (tick) begin
                lclk <= ~lclk;
                if (lclk && run) cnt <= cnt + 8'd1;   // data changes with the falling edge
            end
        end
    end

    always @(*) begin
        case (reg_addr)
            7'h10: reg_rdata = ctrl;
            7'h11: reg_rdata = cnt;
            7'h12: reg_rdata = {5'd0, div};
            default: reg_rdata = 8'h00;
        endcase
    end

    // signal index -> bit: 0..3 (GPIO12..15) carry bits 4..7; 4..7 (GPIO8..11) carry bits 0..3
    assign rp_out = {1'b0, lclk, cnt[3:0], cnt[7:4]};
    assign hdr_out = 10'd0;
    assign hdr_oe  = 10'd0;
    assign fifo_tx_ready = 1'b0;
    assign fifo_rx_data  = 8'd0;
    assign fifo_rx_valid = 1'b0;

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{1'b0, hdr_in, rp_in, reg_rd, fifo_tx_data, fifo_tx_valid, fifo_rx_ready, reg_wdata[7:3]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
