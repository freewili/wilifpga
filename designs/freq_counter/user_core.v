// user_core.v - design "freq_counter": rising-edge counters on three header
// inputs (UART_RX, UART_CTS, GPIO26 = FPGA_IN) and a 1 kHz test square wave on
// GPIO27 (FPGA_OUT) so a header jumper 27 -> 26 proves the counter.
//
// Registers (absolute):
//   0x10-0x12 UART_RX  edge count, 24-bit little endian (snapshot)
//   0x13-0x15 UART_CTS edge count
//   0x16-0x18 GPIO26   edge count
//   0x20 W  bit0: latch live -> snapshot (free-running mode); bit1: clear live counters
//   0x21 RW gate mode: 0 = free running (snapshot follows live, see below),
//                      1 = 1 s gate: every 31 250 000 clocks snapshot <= live, live <= 0
//                          (snapshot then reads Hz). Writing 0x21 clears the live
//                          counters and restarts the gate timer.
//   0x22 R  bit0: a gate result landed since 0x22 was last read (clears on read)
//           bit1: current GPIO27 test level
// Snapshot consistency: while the host is bursting one counter's three bytes
// (between reg_rd of its first byte and reg_rd of its last byte) the snapshot
// is frozen; in free-running mode it otherwise follows the live counter every
// clock, in gated mode a gate boundary inside a burst is applied when the burst
// ends. Edge detection uses a two-stage synchroniser, so inputs up to about
// fabric_clk / 3 (~10 MHz) are counted.
`include "fw2_profile.vh"

module user_core
#
(
  parameter [24:0] GATE_CLOCKS = 25'd31_250_000   // 1 s at 31.25 MHz (testbenches shrink it)
)
(
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

localparam [24:0] GATE_LAST  = GATE_CLOCKS - 25'd1;
localparam [13:0] TEST_LAST  = 14'd15_624;          // 1 kHz on GPIO27: toggle every 15 625 clocks
localparam [6:0] REG_CNT_BASE = 7'h10;              // 0x10..0x18
localparam [6:0] REG_LATCH    = 7'h20;
localparam [6:0] REG_MODE     = 7'h21;
localparam [6:0] REG_STATUS   = 7'h22;

// Input synchronisers and edge detect: 0 = UART_RX, 1 = UART_CTS, 2 = GPIO26
wire [2:0] raw = {hdr_in[`FW2_SIG_GPIO26], hdr_in[`FW2_SIG_UART_CTS], hdr_in[`FW2_SIG_UART_RX]};
reg  [2:0] sync0 = 3'b0, sync1 = 3'b0, sync2 = 3'b0;
wire [2:0] rise = sync1 & ~sync2;

reg [23:0] live [0:2];
reg [23:0] snap [0:2];
reg        gate_mode   = 1'b0;
reg [24:0] gate_cnt    = 25'd0;
reg        gate_pending = 1'b0;   // gate boundary deferred by a burst
reg        gate_flag   = 1'b0;    // 0x22 bit0
reg        burst       = 1'b0;    // a 3-byte counter read is in progress
reg [13:0] test_cnt    = 14'd0;
reg        test_out    = 1'b0;
integer    i;

// Which counter / byte does an address select?
wire       addr_in_cnt = (reg_addr >= REG_CNT_BASE) && (reg_addr <= REG_CNT_BASE + 7'd8);
reg  [1:0] cnt_sel;                                           // which counter
reg  [1:0] byte_sel;                                          // which byte of it
always @(*) begin
  case (reg_addr[3:0])
    4'h0: begin cnt_sel = 2'd0; byte_sel = 2'd0; end
    4'h1: begin cnt_sel = 2'd0; byte_sel = 2'd1; end
    4'h2: begin cnt_sel = 2'd0; byte_sel = 2'd2; end
    4'h3: begin cnt_sel = 2'd1; byte_sel = 2'd0; end
    4'h4: begin cnt_sel = 2'd1; byte_sel = 2'd1; end
    4'h5: begin cnt_sel = 2'd1; byte_sel = 2'd2; end
    4'h6: begin cnt_sel = 2'd2; byte_sel = 2'd0; end
    4'h7: begin cnt_sel = 2'd2; byte_sel = 2'd1; end
    default: begin cnt_sel = 2'd2; byte_sel = 2'd2; end
  endcase
end
wire       rd_first    = reg_rd && addr_in_cnt && (byte_sel == 2'd0);
wire       rd_last     = reg_rd && addr_in_cnt && (byte_sel == 2'd2);

wire       gate_tick   = gate_mode && (gate_cnt == GATE_LAST);
wire       latch_wr    = reg_wr && reg_addr == REG_LATCH;

always @(posedge clk) begin
  sync0 <= raw;
  sync1 <= sync0;
  sync2 <= sync1;
  if (!rst_n) begin
    for (i = 0; i < 3; i = i + 1) begin live[i] <= 24'd0; snap[i] <= 24'd0; end
    gate_mode    <= 1'b0;
    gate_cnt     <= 25'd0;
    gate_pending <= 1'b0;
    gate_flag    <= 1'b0;
    burst        <= 1'b0;
    test_cnt     <= 14'd0;
    test_out     <= 1'b0;
  end else begin
    // 1 kHz test output
    if (test_cnt == TEST_LAST) begin
      test_cnt <= 14'd0;
      test_out <= ~test_out;
    end else begin
      test_cnt <= test_cnt + 14'd1;
    end

    // Burst tracking: freeze snapshots while a counter's three bytes go out.
    // reg_rd fires AFTER a byte is shifted; the first byte was captured from
    // the live snapshot, so freezing from here keeps bytes 2 and 3 consistent
    // with each other and (within one SCK byte time) with byte 1.
    if (rd_first)     burst <= 1'b1;
    else if (rd_last) burst <= 1'b0;

    // Edge counters
    for (i = 0; i < 3; i = i + 1) begin
      if (latch_wr && reg_wdata[1]) live[i] <= 24'd0;
      else if (gate_tick)           live[i] <= {23'd0, rise[i]};
      else if (rise[i])             live[i] <= live[i] + 24'd1;
    end

    // Gate timer
    if (!gate_mode || gate_tick) gate_cnt <= 25'd0;
    else                         gate_cnt <= gate_cnt + 25'd1;

    // Snapshot
    if (gate_mode) begin
      if (gate_tick) begin
        if (burst) gate_pending <= 1'b1;
        else begin
          for (i = 0; i < 3; i = i + 1) snap[i] <= live[i];
          gate_flag <= 1'b1;
        end
      end else if (gate_pending && !burst) begin
        // live was cleared at the tick and has counted on since; the deferred
        // result is approximate by the burst length (microseconds)
        for (i = 0; i < 3; i = i + 1) snap[i] <= live[i];
        gate_pending <= 1'b0;
        gate_flag    <= 1'b1;
      end
    end else begin
      if (latch_wr && reg_wdata[0]) begin
        for (i = 0; i < 3; i = i + 1) snap[i] <= live[i];
      end else if (!burst) begin
        for (i = 0; i < 3; i = i + 1) snap[i] <= live[i];
      end
    end

    if (reg_rd && reg_addr == REG_STATUS) gate_flag <= 1'b0;

    // Writing the mode starts a fresh measurement: counters and gate timer
    // cleared, so the first gated result covers exactly one gate.
    if (reg_wr && reg_addr == REG_MODE) begin
      gate_mode    <= reg_wdata[0];
      gate_pending <= 1'b0;
      gate_cnt     <= 25'd0;
      for (i = 0; i < 3; i = i + 1) live[i] <= 24'd0;
    end
  end
end

wire [23:0] snap_sel = snap[cnt_sel];
always @(*) begin
  if (addr_in_cnt) begin
    case (byte_sel)
      2'd0:    reg_rdata = snap_sel[7:0];
      2'd1:    reg_rdata = snap_sel[15:8];
      default: reg_rdata = snap_sel[23:16];
    endcase
  end else if (reg_addr == REG_MODE)   reg_rdata = {7'b0, gate_mode};
  else if (reg_addr == REG_STATUS)     reg_rdata = {6'b0, test_out, gate_flag};
  else                                 reg_rdata = 8'h00;
end

assign hdr_out = {9'b0, test_out} << `FW2_SIG_GPIO27;   // 1 kHz test output on GPIO27
assign hdr_oe  = 10'b1 << `FW2_SIG_GPIO27;

assign rp_out        = 10'b0;
assign fifo_tx_ready = 1'b0;
assign fifo_rx_data  = 8'h00;
assign fifo_rx_valid = 1'b0;

/* verilator lint_off UNUSEDSIGNAL */
wire unused = &{1'b0, hdr_in, rp_in, fifo_tx_data, fifo_tx_valid, fifo_rx_ready, reg_wdata[7:2]};
/* verilator lint_on UNUSEDSIGNAL */

endmodule
