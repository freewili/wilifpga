// ---------------------------------------------------------------------------
// fw2_fifo_sync.v - synchronous byte FIFO used by fw2_stream_fifo (new code,
// FreeWili 2 FPGA BSP, 2026). Depth 2**AW, inferred into iCE40 EBR by yosys.
// The head word is re-fetched every clock from mem[next rd_ptr], so a pop
// presents the following byte one clock later; `valid` hides the one-clock
// read-before-write window after a push into an empty FIFO.
// ---------------------------------------------------------------------------

module fw2_fifo_sync
#
(
  parameter integer AW = 8   // depth = 2**AW bytes
)
(
  input  wire        clk,
  input  wire        clr,          // synchronous clear
  input  wire        push,
  input  wire [7:0]  wdata,
  input  wire        pop,
  output wire [7:0]  rdata,        // head byte, valid when `valid`
  output wire        valid,
  output wire        full,
  output wire        empty,
  output wire [AW:0] count
);

reg [7:0]  mem [0:(1<<AW)-1];
reg [AW:0] wr_ptr = {(AW+1){1'b0}};
reg [AW:0] rd_ptr = {(AW+1){1'b0}};
reg [7:0]  rdata_q = 8'h00;
reg        stale   = 1'b0;   // head was written in the cycle it was fetched

assign empty = (wr_ptr == rd_ptr);
assign full  = (wr_ptr[AW] != rd_ptr[AW]) && (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
assign count = wr_ptr - rd_ptr;

wire do_push = push & ~full;
wire do_pop  = pop  & ~empty;
wire [AW-1:0] rd_addr_next = do_pop ? (rd_ptr[AW-1:0] + {{(AW-1){1'b0}}, 1'b1}) : rd_ptr[AW-1:0];

always @(posedge clk) begin
  if (do_push) begin
    mem[wr_ptr[AW-1:0]] <= wdata;
  end
  rdata_q <= mem[rd_addr_next];
  // A byte written to the address we are fetching this cycle is not yet in
  // rdata_q next cycle (read-before-write); mark the head invalid for one clock.
  stale   <= do_push & (wr_ptr[AW-1:0] == rd_addr_next);
  if (clr) begin
    wr_ptr <= {(AW+1){1'b0}};
    rd_ptr <= {(AW+1){1'b0}};
  end else begin
    if (do_push) wr_ptr <= wr_ptr + {{AW{1'b0}}, 1'b1};
    if (do_pop)  rd_ptr <= rd_ptr + {{AW{1'b0}}, 1'b1};
  end
end

assign valid = ~empty & ~stale;
assign rdata = valid ? rdata_q : 8'h00;

endmodule
