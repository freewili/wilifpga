// user_core.v - design "logic_capture": an 8-channel logic sampler into the
// stream FIFO (T1 data path). Inputs: the eight shifter-driven header signals
// (FW2_SIG 0..7: spi_miso, spi_cs, spi_sclk, spi_mosi, uart_tx, uart_rx,
// uart_cts, uart_rts) as FPGA_IN; GPIO26 (FPGA_IN) is the trigger input.
// One byte per sample, bit i = signal i, pushed into the FPGA -> host FIFO
// (register 0x61); the host drains with hold-address bursts.
//
// Registers (absolute):
//   0x10 RW sample divider: one sample every (div + 1) clocks (0 = 31.25 MS/s)
//   0x11 RW control: bit0 run (continuous), bit1 one-shot (stop when the FIFO
//                    fills), bit2 wait for trigger before the first sample.
//                    Writing bit0 = 1 (re)starts; bit0 clears itself when a
//                    one-shot completes.
//   0x12 RW trigger: bits[1:0] 0 = none, 1 = rising edge on GPIO26,
//                    2 = falling edge, 3 = any edge
//   0x13 R  status: bit0 running, bit1 triggered (capturing), bit2 done
//                   (one-shot filled the FIFO), bit3 dropped (a sample was
//                   lost because the FIFO was full while running continuously)
//   0x14 R  current input byte (live, for a sanity check without the FIFO)
// Capture depth per one-shot = the shell's RX FIFO (4096 bytes).
`include "fw2_profile.vh"

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
  output wire [7:0] fifo_rx_data,
  output wire       fifo_rx_valid,
  input  wire       fifo_rx_ready
);

localparam [6:0] REG_DIV    = 7'h10;
localparam [6:0] REG_CTRL   = 7'h11;
localparam [6:0] REG_TRIG   = 7'h12;
localparam [6:0] REG_STATUS = 7'h13;
localparam [6:0] REG_LIVE   = 7'h14;

reg [7:0] div      = 8'd0;
reg [7:0] div_cnt  = 8'd0;
reg       run      = 1'b0;
reg       one_shot = 1'b0;
reg       wait_trg = 1'b0;
reg [1:0] trig_cfg = 2'd0;
reg       triggered = 1'b0;
reg       done     = 1'b0;
reg       dropped  = 1'b0;
reg       have     = 1'b0;    // a sample is waiting for the FIFO
reg [7:0] samp     = 8'h00;

// Synchronised inputs
reg [7:0] in_s0 = 8'h00, in_s1 = 8'h00;
reg       trg_s0 = 1'b0, trg_s1 = 1'b0, trg_s2 = 1'b0;
wire      trg_rise = trg_s1 & ~trg_s2;
wire      trg_fall = ~trg_s1 & trg_s2;
wire      trg_hit  = (trig_cfg == 2'd1) ? trg_rise :
                     (trig_cfg == 2'd2) ? trg_fall :
                     (trig_cfg == 2'd3) ? (trg_rise | trg_fall) : 1'b1;

wire tick = (div_cnt == div);
wire capturing = run & (triggered | ~wait_trg);

// Stream handshake: a push is accepted in the cycle fifo_rx_valid and
// fifo_rx_ready are both high, so the sample is HELD until accepted (never
// decide on last cycle's ready).
wire accept = have & fifo_rx_ready;
assign fifo_rx_valid = have;
assign fifo_rx_data  = samp;

always @(posedge clk) begin
  in_s0  <= hdr_in[7:0];
  in_s1  <= in_s0;
  trg_s0 <= hdr_in[`FW2_SIG_GPIO26];
  trg_s1 <= trg_s0;
  trg_s2 <= trg_s1;
  if (!rst_n) begin
    div <= 8'd0; div_cnt <= 8'd0;
    run <= 1'b0; one_shot <= 1'b0; wait_trg <= 1'b0; trig_cfg <= 2'd0;
    triggered <= 1'b0; done <= 1'b0; dropped <= 1'b0;
    have <= 1'b0; samp <= 8'h00;
  end else begin
    if (accept) have <= 1'b0;

    if (reg_wr) begin
      case (reg_addr)
        REG_DIV:  div <= reg_wdata;
        REG_CTRL: begin
          run      <= reg_wdata[0];
          one_shot <= reg_wdata[1];
          wait_trg <= reg_wdata[2];
          triggered <= 1'b0;
          done     <= 1'b0;
          dropped  <= 1'b0;
          div_cnt  <= 8'd0;
          have     <= 1'b0;
        end
        REG_TRIG: trig_cfg <= reg_wdata[1:0];
        default: ;
      endcase
    end else if (run) begin
      if (!triggered && wait_trg && trg_hit) triggered <= 1'b1;
      if (capturing) begin
        if (tick) begin
          div_cnt <= 8'd0;
          if (!have || accept) begin
            samp <= in_s1;              // slot free (or freed this cycle)
            have <= 1'b1;
          end else if (one_shot) begin
            run  <= 1'b0;               // FIFO full: one-shot complete
            done <= 1'b1;
            have <= 1'b0;               // drop the unaccepted sample
          end else begin
            dropped <= 1'b1;            // continuous mode: host is too slow
          end
        end else begin
          div_cnt <= div_cnt + 8'd1;
        end
      end
    end
  end
end

always @(*) begin
  case (reg_addr)
    REG_DIV:    reg_rdata = div;
    REG_CTRL:   reg_rdata = {5'b0, wait_trg, one_shot, run};
    REG_TRIG:   reg_rdata = {6'b0, trig_cfg};
    REG_STATUS: reg_rdata = {4'b0, dropped, done, triggered | (run & ~wait_trg), run};
    REG_LIVE:   reg_rdata = in_s1;
    default:    reg_rdata = 8'h00;
  endcase
end

assign hdr_out       = 10'b0;
assign hdr_oe        = 10'b0;
assign rp_out        = 10'b0;
assign fifo_tx_ready = 1'b0;

/* verilator lint_off UNUSEDSIGNAL */
wire unused = &{1'b0, hdr_in[9], rp_in, reg_rd, fifo_tx_data, fifo_tx_valid};
/* verilator lint_on UNUSEDSIGNAL */

endmodule
