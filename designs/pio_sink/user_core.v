// pio_sink - RP2350 -> FPGA link checker.
//
// The RP2350's PIO puts a byte on GPIO8-15 while it drives the link clock
// (GPIO26) low, then raises the clock. If its TX FIFO runs dry the PIO stalls
// with the clock low, so the FPGA simply sees no edge (lossless). The core
// oversamples clock and data through identical 2-flop synchronisers and, on
// each rising edge, takes the byte, checks it is the previous byte + 1, and
// counts bytes and errors.
//
// Byte bit k arrives on the signal whose RP2350 GPIO is 8+k (same as pio_link):
//   bits 0..3 <- uart_tx(8) uart_rx(9) uart_cts(10) uart_rts(11) = signals 4..7
//   bits 4..7 <- spi_miso(12) spi_cs(13) spi_sclk(14) spi_mosi(15) = signals 0..3
//
// Registers (absolute):
//   0x10  write bit0 = 1: clear counts (the next byte starts a new sequence)
//   0x11..0x14  bytes received since clear, u32 LE (RO)
//   0x15..0x18  pattern errors since clear, u32 LE (RO)
//   0x19  last byte received (RO)
//   0x1A  first byte received since clear (RO)
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
    // byte and clock from the inner nets, through identical synchronisers
    wire [7:0] raw = {rp_in[3:0], rp_in[7:4]};
    reg  [8:0] s1 = 9'd0, s2 = 9'd0;
    reg        clk_prev = 1'b0;
    always @(posedge clk) begin
        s1 <= {rp_in[8], raw};
        s2 <= s1;
        clk_prev <= s2[8];
    end
    wire       rise = s2[8] & ~clk_prev;
    wire [7:0] data = s2[7:0];

    reg [31:0] count  = 32'd0;
    reg [31:0] errors = 32'd0;
    reg [7:0]  last   = 8'h00;
    reg [7:0]  first  = 8'h00;
    reg        have   = 1'b0;

    always @(posedge clk) begin
        if (!rst_n || (reg_wr && reg_addr == 7'h10 && reg_wdata[0])) begin
            count  <= 32'd0;
            errors <= 32'd0;
            have   <= 1'b0;
            last   <= 8'h00;
            first  <= 8'h00;
        end else if (rise) begin
            count <= count + 32'd1;
            if (have && data != last + 8'd1)
                errors <= errors + 32'd1;
            if (!have)
                first <= data;
            last <= data;
            have <= 1'b1;
        end
    end

    always @(*) begin
        case (reg_addr)
            7'h11: reg_rdata = count[7:0];
            7'h12: reg_rdata = count[15:8];
            7'h13: reg_rdata = count[23:16];
            7'h14: reg_rdata = count[31:24];
            7'h15: reg_rdata = errors[7:0];
            7'h16: reg_rdata = errors[15:8];
            7'h17: reg_rdata = errors[23:16];
            7'h18: reg_rdata = errors[31:24];
            7'h19: reg_rdata = last;
            7'h1A: reg_rdata = first;
            default: reg_rdata = 8'h00;
        endcase
    end

    assign rp_out  = 10'd0;    // every link signal is an input here
    assign hdr_out = 10'd0;
    assign hdr_oe  = 10'd0;
    assign fifo_tx_ready = 1'b0;
    assign fifo_rx_data  = 8'd0;
    assign fifo_rx_valid = 1'b0;

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{1'b0, hdr_in, rp_in[9], reg_rd, fifo_tx_data, fifo_tx_valid, fifo_rx_ready,
                    reg_wdata[7:1]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
