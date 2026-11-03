// ---------------------------------------------------------------------------
// Test user core for tb_shell: drives EVERY output it has (all hdr_oe, all
// hdr_out, all rp_out) so the testbench can prove the shell's arm gate and
// profile tie-offs, mirrors its inputs into registers, and exercises the
// stream FIFO with a pattern generator. Not a design: only used by fpga/sim.
//
// Registers (absolute):
//   0x10-0x17 RW scratch
//   0x18 RO last byte popped from the TX FIFO (host -> FPGA)
//   0x19 RO number of TX FIFO bytes popped (mod 256)
//   0x1A RO hdr_in[7:0]      0x1B RO {6'b0, hdr_in[9:8]}
//   0x1C RO rp_in[7:0]       0x1D RO {6'b0, rp_in[9:8]}
//   0x1E RW hdr_out[7:0] / rp_out[7:0] value (default 0xFF)
//   0x1F RW {6'b0, hdr_out[9:8]} (default 0x03)
//   0x20 RW pattern count low, 0x21 RW pattern count high
//   0x22 WO any write: push count bytes (seed, seed+1, ...) into the RX FIFO
//   0x23 RW pattern seed
//   0x24 RO number of reg_rd strobes seen for 0x24 (clear-on-read test)
//   0x25 RW bit0: pattern generator ignores fifo_rx_ready (overrun test)
// ---------------------------------------------------------------------------
module user_core
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
  output reg  [7:0] fifo_rx_data,
  output reg        fifo_rx_valid,
  input  wire       fifo_rx_ready
);

reg [7:0]  scratch [0:7];
reg [7:0]  last_tx  = 8'h00;
reg [7:0]  tx_count = 8'h00;
reg [9:0]  out_val  = 10'h3FF;
reg [15:0] pat_count = 16'd0;
reg [15:0] pat_left  = 16'd0;
reg [7:0]  pat_seed  = 8'h00;
reg [7:0]  pat_next  = 8'h00;
reg [7:0]  rd_hits   = 8'h00;
reg        force_push = 1'b0;
integer i;

assign hdr_out = out_val;
assign hdr_oe  = 10'h3FF;
assign rp_out  = out_val;

// Pop the TX FIFO whenever it has a byte
assign fifo_tx_ready = fifo_tx_valid;

always @(posedge clk) begin
  if (!rst_n) begin
    for (i = 0; i < 8; i = i + 1) scratch[i] <= 8'h00;
    last_tx   <= 8'h00;
    tx_count  <= 8'h00;
    out_val   <= 10'h3FF;
    pat_count <= 16'd0;
    pat_left  <= 16'd0;
    pat_seed  <= 8'h00;
    pat_next  <= 8'h00;
    rd_hits   <= 8'h00;
    force_push <= 1'b0;
    fifo_rx_valid <= 1'b0;
    fifo_rx_data  <= 8'h00;
  end else begin
    if (fifo_tx_valid) begin
      last_tx  <= fifo_tx_data;
      tx_count <= tx_count + 8'd1;
    end
    // Pattern generator: one push per clock while the FIFO accepts
    fifo_rx_valid <= 1'b0;
    if (pat_left != 16'd0 && (fifo_rx_ready || force_push) && !fifo_rx_valid) begin
      fifo_rx_data  <= pat_next;
      fifo_rx_valid <= 1'b1;
      pat_next      <= pat_next + 8'd1;
      pat_left      <= pat_left - 16'd1;
    end
    if (reg_rd && reg_addr == 7'h24) rd_hits <= rd_hits + 8'd1;
    if (reg_wr) begin
      case (reg_addr)
        7'h10, 7'h11, 7'h12, 7'h13, 7'h14, 7'h15, 7'h16, 7'h17:
          scratch[reg_addr[2:0]] <= reg_wdata;
        7'h1E: out_val[7:0] <= reg_wdata;
        7'h1F: out_val[9:8] <= reg_wdata[1:0];
        7'h20: pat_count[7:0]  <= reg_wdata;
        7'h21: pat_count[15:8] <= reg_wdata;
        7'h22: begin pat_left <= pat_count; pat_next <= pat_seed; end
        7'h23: pat_seed <= reg_wdata;
        7'h25: force_push <= reg_wdata[0];
        default: ;
      endcase
    end
  end
end

always @(*) begin
  case (reg_addr)
    7'h10, 7'h11, 7'h12, 7'h13, 7'h14, 7'h15, 7'h16, 7'h17: reg_rdata = scratch[reg_addr[2:0]];
    7'h18: reg_rdata = last_tx;
    7'h19: reg_rdata = tx_count;
    7'h1A: reg_rdata = hdr_in[7:0];
    7'h1B: reg_rdata = {6'b0, hdr_in[9:8]};
    7'h1C: reg_rdata = rp_in[7:0];
    7'h1D: reg_rdata = {6'b0, rp_in[9:8]};
    7'h1E: reg_rdata = out_val[7:0];
    7'h1F: reg_rdata = {6'b0, out_val[9:8]};
    7'h20: reg_rdata = pat_count[7:0];
    7'h21: reg_rdata = pat_count[15:8];
    7'h23: reg_rdata = pat_seed;
    7'h24: reg_rdata = rd_hits;
    7'h25: reg_rdata = {7'b0, force_push};
    default: reg_rdata = 8'h00;
  endcase
end

endmodule
