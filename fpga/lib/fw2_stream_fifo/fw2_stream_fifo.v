// ---------------------------------------------------------------------------
// fw2_stream_fifo.v - register-bus stream FIFO for the FW2 shell (new code,
// FreeWili 2 FPGA BSP, 2026). Two EBR-backed byte FIFOs:
//   TX (host -> FPGA): host pushes by writing register 0x60, user core pops
//   RX (FPGA -> host): user core pushes, host pops by reading register 0x61
// Registers (offsets from 0x60, see fw2_regs.vh): 0 TX data, 1 RX data,
// 2 status, 3 control, 4..7 RX count LE. Hold-address bursts on 0/1 are
// provided by fw2_spi_slave; this module only sees push/pop strobes.
// Backing store: fw2_fifo_sync.v (same directory). A pop presents the next
// byte one clock later; the SPI slave samples it about 4 fabric clocks after
// the pop at 3.25 MHz SCK.
// ---------------------------------------------------------------------------

module fw2_stream_fifo
#
(
  parameter integer RX_AW = 12,  // FPGA -> host depth: 4096 bytes (8 EBR)
  parameter integer TX_AW = 8    // host -> FPGA depth: 256 bytes (1 EBR)
)
(
  input  wire        clk,
  input  wire        rst,            // synchronous, active high
  // Host register side (offsets within the 0x60 window)
  input  wire [3:0]  host_addr,      // current bus address[3:0] (for host_rdata)
  output reg  [7:0]  host_rdata,
  input  wire        host_wr,        // one-cycle strobe: host_wdata written at host_addr
  input  wire [7:0]  host_wdata,
  input  wire        host_rd_done,   // one-cycle strobe: byte at host_rd_addr was shifted out
  input  wire [3:0]  host_rd_addr,
  // User core side (host point of view: TX = host -> FPGA, RX = FPGA -> host)
  output wire [7:0]  fifo_tx_data,
  output wire        fifo_tx_valid,
  input  wire        fifo_tx_ready,
  input  wire [7:0]  fifo_rx_data,
  input  wire        fifo_rx_valid,
  output wire        fifo_rx_ready
);

localparam [3:0] OFF_TX = 4'h0, OFF_RX = 4'h1, OFF_STAT = 4'h2, OFF_CTRL = 4'h3,
                 OFF_CNT0 = 4'h4, OFF_CNT1 = 4'h5, OFF_CNT2 = 4'h6, OFF_CNT3 = 4'h7;

wire tx_push = host_wr & (host_addr == OFF_TX);
wire rx_pop  = host_rd_done & (host_rd_addr == OFF_RX);
wire ctrl_wr = host_wr & (host_addr == OFF_CTRL);
wire stat_rd = host_rd_done & (host_rd_addr == OFF_STAT);

wire rx_flush  = rst | (ctrl_wr & host_wdata[0]);
wire tx_flush  = rst | (ctrl_wr & host_wdata[1]);
wire clr_flags = rst | (ctrl_wr & host_wdata[2]) | stat_rd;

wire [7:0] tx_rdata, rx_rdata;
wire tx_valid, tx_full, tx_empty, rx_full, rx_empty;
/* verilator lint_off UNUSEDSIGNAL */
wire [TX_AW:0] tx_count;
wire rx_valid;          // rx_rdata is already 0x00 while invalid
/* verilator lint_on UNUSEDSIGNAL */
wire [RX_AW:0] rx_count;

fw2_fifo_sync #(.AW(TX_AW)) u_tx (
  .clk(clk), .clr(tx_flush),
  .push(tx_push), .wdata(host_wdata),
  .pop(fifo_tx_ready), .rdata(tx_rdata), .valid(tx_valid),
  .full(tx_full), .empty(tx_empty), .count(tx_count)
);

fw2_fifo_sync #(.AW(RX_AW)) u_rx (
  .clk(clk), .clr(rx_flush),
  .push(fifo_rx_valid), .wdata(fifo_rx_data),
  .pop(rx_pop), .rdata(rx_rdata), .valid(rx_valid),
  .full(rx_full), .empty(rx_empty), .count(rx_count)
);

assign fifo_tx_data  = tx_rdata;
assign fifo_tx_valid = tx_valid;
assign fifo_rx_ready = ~rx_full;

// Sticky flags
reg rx_overrun = 1'b0, tx_overrun = 1'b0, rx_underrun = 1'b0;
always @(posedge clk) begin
  if (clr_flags) begin
    rx_overrun  <= 1'b0;
    tx_overrun  <= 1'b0;
    rx_underrun <= 1'b0;
  end else begin
    if (fifo_rx_valid & rx_full) rx_overrun  <= 1'b1;
    if (tx_push & tx_full)       tx_overrun  <= 1'b1;
    if (rx_pop & rx_empty)       rx_underrun <= 1'b1;
  end
end

wire [31:0] rx_count32 = {{(31-RX_AW){1'b0}}, rx_count};
wire [7:0]  status = {1'b1, rx_underrun, tx_overrun, rx_overrun, tx_full, tx_empty, rx_full, rx_empty};

always @(*) begin
  case (host_addr)
    OFF_TX:   host_rdata = 8'h00;
    OFF_RX:   host_rdata = rx_rdata;
    OFF_STAT: host_rdata = status;
    OFF_CTRL: host_rdata = 8'h00;
    OFF_CNT0: host_rdata = rx_count32[7:0];
    OFF_CNT1: host_rdata = rx_count32[15:8];
    OFF_CNT2: host_rdata = rx_count32[23:16];
    OFF_CNT3: host_rdata = rx_count32[31:24];
    default:  host_rdata = 8'h00;
  endcase
end

endmodule
