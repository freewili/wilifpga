// ---------------------------------------------------------------------------
// fw2_shell.v - the mandatory top of every FreeWili 2 FPGA design (FW2 FPGA
// design contract, docs/fpga-design-contract.md). New code, 2026.
//
// Owns every pad of fpga/constraints/fw2.pcf (same port names as the stock
// main.v so the constraints apply unchanged) and provides:
//   * fw2_io_buffer   : profile-driven pad directions, arm gate (rule 9)
//   * fw2_spi_slave   : the SPI register bus (stock protocol, + hold-address
//                       bursts for the FIFO), active only inside IO_CONFIG_ENABLE
//   * shell registers : 0x01 reset, 0x02/0x03 direction readback, 0x0F IO_ARM,
//                       0x0D/0x0E pad-readback contention flags (sticky, clear on read)
//   * stream FIFO     : 0x60-0x6F (when FW2_CAP_STREAM is set in the design caps)
//   * ID block        : 0x70-0x7F, constants from fw2_design_id.vh
//   * user_core       : the design's module, fixed port list (fw2_user_core.vh)
// Unused pads (I2C tap, PSRAM, CM0 link) are parked in a safe idle state;
// every bidirectional pad is an explicit SB_IO via fw2_pad (see fw2_pad.v).
//
// Includes resolved with -I fpga/shell and -I <dir holding fw2_design_id.vh>.
// ---------------------------------------------------------------------------
`include "fw2_profile.vh"
`include "fw2_regs.vh"
`include "fw2_design_id.vh"

module fw2_shell
(
  // SPI1 to/from RP2350 (inner net)
  inout  wire SPI_MISO_Rp,
  inout  wire SPI_MOSI_Rp,
  inout  wire SPI_Clk_Rp,
  inout  wire SPI_CS_Rp,
  // SPI1 to/from IO header (outer net)
  inout  wire SPI_MISO_Out,
  inout  wire SPI_MOSI_Out,
  inout  wire SPI_Clk_Out,
  inout  wire SPI_CS_Out,
  // UART1 to/from RP2350
  inout  wire UART_Tx_Rp,
  inout  wire UART_Rx_Rp,
  inout  wire UART_CTS_Rp,
  inout  wire UART_RTS_Rp,
  // UART1 to/from IO header
  inout  wire UART_Tx_Out,
  inout  wire UART_Rx_Out,
  inout  wire UART_CTS_Out,
  inout  wire UART_RTS_Out,
  // GPIO to/from RP2350
  inout  wire GPIO_26_Rp,
  inout  wire GPIO_27_Rp,
  // GPIO to/from IO header
  inout  wire GPIO_26_Out,
  inout  wire GPIO_27_Out,

  input  wire CLK,

  // I2C0 tap (optional stock I2C slave; not used by the shell in v1)
  inout  wire I2C_SDA,
  /* verilator lint_off UNUSEDSIGNAL */
  input  wire I2C_SCL,
  /* verilator lint_on UNUSEDSIGNAL */

  input  wire IO_CONFIG_ENABLE,
  output wire GPIO_26_Dir,
  output wire GPIO_27_Dir,

  // PSRAM (not used by the shell in v1: parked deselected)
  output wire SRAM_CLK,
  output wire SRAM_CS,
  inout  wire SRAM_IO0,
  inout  wire SRAM_IO1,
  inout  wire SRAM_IO2,
  inout  wire SRAM_IO3,

  // CM0 link (not used by the shell in v1: outputs idle high, inputs ignored)
  /* verilator lint_off UNUSEDSIGNAL */
  input  wire CM0_SPI0_MISO,
  input  wire CM0_SPI0_CLK,
  input  wire CM0_RX1,
  input  wire CM0_SPI1_MISO,
  input  wire CM0_SPI1_CLK,
  /* verilator lint_on UNUSEDSIGNAL */
  output wire CM0_RX0,
  output wire CM0_CTS0
);

// ====================== //
// ==== Declarations ==== //
// ====================== //

localparam [29:0] PROFILE = `FW2_PACK_PROFILE;
localparam [7:0]  CAPS    = `FW2_DESIGN_CAPS;
localparam        HAS_STREAM = CAPS[`FW2_CAP_STREAM];

wire       resetn;            // power-up and register 0x01 reset, active low

// Register bus
wire       bus_wr;
wire [6:0] bus_addr;
wire [7:0] bus_wdata;
wire       bus_valid;
wire       bus_rd_done;
wire [6:0] bus_rd_addr;
reg  [7:0] bus_rdata;
wire       bus_miso;
wire       bus_hold;
wire       wr_strobe = IO_CONFIG_ENABLE & bus_wr & bus_valid;

// Shell registers
reg        io_arm          = 1'b0;
reg        reset_since_arm = 1'b0;
wire [9:0] dir_bits;
wire [7:0] rd_rst;

// User core bundles
wire [9:0] hdr_in, hdr_out, hdr_oe, rp_in, rp_out;
wire [6:0] reg_addr;
wire       reg_wr, reg_rd;
wire [7:0] reg_rdata;
wire [7:0] fifo_tx_data;
wire       fifo_tx_valid, fifo_tx_ready;
wire [7:0] fifo_rx_data;
wire       fifo_rx_valid, fifo_rx_ready;
wire [7:0] fifo_rdata;

// ============================ //
// ==== Pads and IO buffer ==== //
// ============================ //

// Every bidirectional pad goes through fw2_pad (an explicit SB_IO under
// synthesis). Do NOT write `assign PAD = en ? x : 1'bz` here: yosys folds a
// constant enable into a driven constant and the pad drives the board (seen on
// hardware with the parked I2C_SDA pad, 2026-10-31). fw2_io_buffer provides the
// per-signal values and enables, bundled by FW2_SIG_* index.
wire [9:0] rp_i, rp_o, rp_oe, hdr_i, hdr_o, hdr_oe_pad;

fw2_pad u_pad_rp0 (.pad(SPI_MISO_Rp),  .o(rp_o[0]), .oe(rp_oe[0]), .i(rp_i[0]));
fw2_pad u_pad_rp1 (.pad(SPI_CS_Rp),    .o(rp_o[1]), .oe(rp_oe[1]), .i(rp_i[1]));
fw2_pad u_pad_rp2 (.pad(SPI_Clk_Rp),   .o(rp_o[2]), .oe(rp_oe[2]), .i(rp_i[2]));
fw2_pad u_pad_rp3 (.pad(SPI_MOSI_Rp),  .o(rp_o[3]), .oe(rp_oe[3]), .i(rp_i[3]));
fw2_pad u_pad_rp4 (.pad(UART_Tx_Rp),   .o(rp_o[4]), .oe(rp_oe[4]), .i(rp_i[4]));
fw2_pad u_pad_rp5 (.pad(UART_Rx_Rp),   .o(rp_o[5]), .oe(rp_oe[5]), .i(rp_i[5]));
fw2_pad u_pad_rp6 (.pad(UART_CTS_Rp),  .o(rp_o[6]), .oe(rp_oe[6]), .i(rp_i[6]));
fw2_pad u_pad_rp7 (.pad(UART_RTS_Rp),  .o(rp_o[7]), .oe(rp_oe[7]), .i(rp_i[7]));
fw2_pad u_pad_rp8 (.pad(GPIO_26_Rp),   .o(rp_o[8]), .oe(rp_oe[8]), .i(rp_i[8]));
fw2_pad u_pad_rp9 (.pad(GPIO_27_Rp),   .o(rp_o[9]), .oe(rp_oe[9]), .i(rp_i[9]));

fw2_pad u_pad_hdr0 (.pad(SPI_MISO_Out), .o(hdr_o[0]), .oe(hdr_oe_pad[0]), .i(hdr_i[0]));
fw2_pad u_pad_hdr1 (.pad(SPI_CS_Out),   .o(hdr_o[1]), .oe(hdr_oe_pad[1]), .i(hdr_i[1]));
fw2_pad u_pad_hdr2 (.pad(SPI_Clk_Out),  .o(hdr_o[2]), .oe(hdr_oe_pad[2]), .i(hdr_i[2]));
fw2_pad u_pad_hdr3 (.pad(SPI_MOSI_Out), .o(hdr_o[3]), .oe(hdr_oe_pad[3]), .i(hdr_i[3]));
fw2_pad u_pad_hdr4 (.pad(UART_Tx_Out),  .o(hdr_o[4]), .oe(hdr_oe_pad[4]), .i(hdr_i[4]));
fw2_pad u_pad_hdr5 (.pad(UART_Rx_Out),  .o(hdr_o[5]), .oe(hdr_oe_pad[5]), .i(hdr_i[5]));
fw2_pad u_pad_hdr6 (.pad(UART_CTS_Out), .o(hdr_o[6]), .oe(hdr_oe_pad[6]), .i(hdr_i[6]));
fw2_pad u_pad_hdr7 (.pad(UART_RTS_Out), .o(hdr_o[7]), .oe(hdr_oe_pad[7]), .i(hdr_i[7]));
fw2_pad u_pad_hdr8 (.pad(GPIO_26_Out),  .o(hdr_o[8]), .oe(hdr_oe_pad[8]), .i(hdr_i[8]));
fw2_pad u_pad_hdr9 (.pad(GPIO_27_Out),  .o(hdr_o[9]), .oe(hdr_oe_pad[9]), .i(hdr_i[9]));

fw2_io_buffer
#
(
  .PROFILE(PROFILE)
)
u_iobuf
(
  .io_config_enable(IO_CONFIG_ENABLE),
  .arm(io_arm),
  .spi_miso_bus(bus_miso),
  .rp_i(rp_i),
  .rp_o(rp_o),
  .rp_oe(rp_oe),
  .hdr_i(hdr_i),
  .hdr_o(hdr_o),
  .hdr_oe_pad(hdr_oe_pad),
  .gpio_26_dir(GPIO_26_Dir),
  .gpio_27_dir(GPIO_27_Dir),
  .hdr_in(hdr_in),
  .hdr_out(hdr_out),
  .hdr_oe(hdr_oe),
  .rp_in(rp_in),
  .rp_out(rp_out),
  .dir_bits(dir_bits)
);

// Pads the v1 shell does not use. I2C_SDA is open-drain and never pulled low
// (no I2C_SLAVE capability in v1), I2C_SCL is an input, the PSRAM data pads are
// inputs with the chip deselected, the CM0 UART nets idle high.
/* verilator lint_off UNUSEDSIGNAL */
wire i2c_sda_in;
wire [3:0] sram_io_in;
/* verilator lint_on UNUSEDSIGNAL */
fw2_pad_od u_pad_sda (.pad(I2C_SDA), .pull_low(1'b0), .i(i2c_sda_in));
fw2_pad u_pad_sram0 (.pad(SRAM_IO0), .o(1'b0), .oe(1'b0), .i(sram_io_in[0]));
fw2_pad u_pad_sram1 (.pad(SRAM_IO1), .o(1'b0), .oe(1'b0), .i(sram_io_in[1]));
fw2_pad u_pad_sram2 (.pad(SRAM_IO2), .o(1'b0), .oe(1'b0), .i(sram_io_in[2]));
fw2_pad u_pad_sram3 (.pad(SRAM_IO3), .o(1'b0), .oe(1'b0), .i(sram_io_in[3]));
assign SRAM_CLK = 1'b0;
assign SRAM_CS  = 1'b1;
assign CM0_RX0  = 1'b1;   // UART idle
assign CM0_CTS0 = 1'b1;   // CTS_n: not ready

// ====================== //
// ==== Register bus ==== //
// ====================== //

fw2_rst_ctrl_reg
#
(
  .G_SPI_BASEADDR(`FW2_REG_RESET)
)
u_rst
(
  .clk(CLK),
  .resetn(resetn),
  .io_config_enable(IO_CONFIG_ENABLE),
  .wr(bus_wr),
  .addr(bus_addr),
  .wr_data(bus_wdata),
  .data_valid(bus_valid),
  .rd_data(rd_rst)
);

// Hold-address bursts for the two FIFO data registers
assign bus_hold = (bus_addr == `FW2_REG_FIFO_TX) | (bus_addr == `FW2_REG_FIFO_RX);

fw2_spi_slave
u_bus
(
  .clk(CLK),
  .resetn(resetn),
  .spi_miso(bus_miso),
  // Fabric must read pads through the SB_IO input (rp_i), never the port
  // net itself, or nextpnr inserts a second IO buffer on the same ball.
  .spi_mosi(rp_i[`FW2_SIG_SPI_MOSI]),
  .spi_cs(rp_i[`FW2_SIG_SPI_CS]),
  .spi_sck(rp_i[`FW2_SIG_SPI_SCLK]),
  .en(IO_CONFIG_ENABLE),
  .hold(bus_hold),
  .wr(bus_wr),
  .addr(bus_addr),
  .wr_data(bus_wdata),
  .data_valid(bus_valid),
  .rd_done(bus_rd_done),
  .rd_done_addr(bus_rd_addr),
  .rd_data(bus_rdata)
);

// IO_ARM register (0x0F). Resets to 0 at power-up and on register 0x01; a
// reset while armed leaves the sticky RESET_SINCE_ARM flag for the firmware.
always @(posedge CLK) begin
  if (resetn == 1'b0) begin
    if (io_arm) reset_since_arm <= 1'b1;
    io_arm <= 1'b0;
  end else if (wr_strobe && bus_addr == `FW2_REG_IO_ARM) begin
    io_arm          <= bus_wdata[0];
    reset_since_arm <= 1'b0;
  end
end

// Stock-format direction readback (0x02 = CTS SCK CS MISO MOSI TX RX RTS,
// 0x03 = {6'b0, GPIO26, GPIO27}); 1 = FPGA drives the header pin.
wire [7:0] iodir_hi = {dir_bits[`FW2_SIG_UART_CTS], dir_bits[`FW2_SIG_SPI_SCLK],
                       dir_bits[`FW2_SIG_SPI_CS],   dir_bits[`FW2_SIG_SPI_MISO],
                       dir_bits[`FW2_SIG_SPI_MOSI], dir_bits[`FW2_SIG_UART_TX],
                       dir_bits[`FW2_SIG_UART_RX],  dir_bits[`FW2_SIG_UART_RTS]};
wire [7:0] iodir_lo = {6'b000000, dir_bits[`FW2_SIG_GPIO26], dir_bits[`FW2_SIG_GPIO27]};

// Fabric readback self-check (0x0D/0x0E). For every FPGA_OUT
// signal the pad's SB_IO input (hdr_i, the real _Out level) is compared with
// what the shell drives (hdr_o while hdr_oe_pad, i.e. hdr_out while armed and
// hdr_oe). CONT_FILTER or more consecutive clocks of disagreement set the signal's
// sticky bit: something on the header side (the level shifter or a device) is
// fighting the FPGA pad, which rule 4 cannot prevent. A pad transition takes
// fewer clocks, so it never sets a bit. Signals in any other mode have no
// detector (constant 0). Flags clear on reset, on disarm, and per byte when
// that byte has been read (rd_done); a hit in the same clock as the clear
// wins, so a fight that is still going on is never lost.
// Filter length in clocks. 4 trips on every rising edge of GPIO27 on the
// bench: its _Out pad (ball 41) is an open-drain RGB pin, so "high" is a
// pull-up and the net needs ~6 clocks (0.19 us, 2026-11-02) to read 1,
// while its
// static level is clean. A real fight lasts as long as both drivers do, so a
// longer filter loses nothing that matters. Overridable for diagnostics.
`ifndef FW2_CONT_FILTER
`define FW2_CONT_FILTER 32
`endif
localparam [7:0] CONT_FILTER = `FW2_CONT_FILTER;
reg  [9:0] contention = 10'd0;
wire [9:0] cont_hit;
wire       cont_rd_lo = bus_rd_done & (bus_rd_addr == `FW2_REG_CONTENTION);
wire       cont_rd_hi = bus_rd_done & (bus_rd_addr == `FW2_REG_CONTENTION_GPIO);
wire [9:0] cont_keep  = {{2{~cont_rd_hi}}, {8{~cont_rd_lo}}};
genvar gi;
generate
  for (gi = 0; gi < 10; gi = gi + 1) begin : g_cont
    localparam [2:0] MODE = PROFILE[3*gi+2 -: 3];
    if (MODE == `FW2_MODE_FPGA_OUT) begin : g_chk
      wire      mism = hdr_oe_pad[gi] & (hdr_i[gi] ^ hdr_o[gi]);
      reg [7:0] run  = 8'd0;   // consecutive mismatch clocks so far, saturating at CONT_FILTER-1
      always @(posedge CLK) begin
        if (!resetn || !mism) run <= 8'd0;
        else if (run != CONT_FILTER - 1) run <= run + 8'd1;
      end
      assign cont_hit[gi] = mism & (run == CONT_FILTER - 1);   // the CONT_FILTER-th consecutive clock
    end else begin : g_none
      assign cont_hit[gi] = 1'b0;
    end
  end
endgenerate
always @(posedge CLK) begin
  if (!resetn || !io_arm) contention <= 10'd0;
  else                    contention <= (contention & cont_keep) | cont_hit;
end

// ID block 0x70-0x7F
wire [15:0] id_design  = `FW2_DESIGN_ID;
wire [15:0] id_version = `FW2_DESIGN_VERSION;
wire [7:0]  id_clock   = `FW2_DESIGN_CLOCK_CODE;
wire [7:0]  id_cksum   = `FW2_DESIGN_CHECKSUM;
wire [31:0] id_profile = {2'b00, PROFILE};  // truthful: packed from the pad profile
reg  [7:0]  id_byte;
always @(*) begin
  case (bus_addr[3:0])
    4'h0: id_byte = `FW2_ID_MAGIC0;
    4'h1: id_byte = `FW2_ID_MAGIC1;
    4'h2: id_byte = `FW2_ID_MAGIC2;
    4'h3: id_byte = `FW2_ID_MAGIC3;
    4'h4: id_byte = `FW2_CONTRACT_VERSION;
    4'h5: id_byte = id_design[7:0];
    4'h6: id_byte = id_design[15:8];
    4'h7: id_byte = id_version[7:0];
    4'h8: id_byte = id_version[15:8];
    4'h9: id_byte = CAPS;
    4'hA: id_byte = id_clock;
    4'hB: id_byte = id_profile[7:0];
    4'hC: id_byte = id_profile[15:8];
    4'hD: id_byte = id_profile[23:16];
    4'hE: id_byte = id_profile[31:24];
    default: id_byte = id_cksum;
  endcase
end

// Read mux
wire in_user = (bus_addr >= `FW2_REG_USER_FIRST) && (bus_addr <= `FW2_REG_USER_LAST);
always @(*) begin
  if (bus_addr[6:4] == 3'b111) begin
    bus_rdata = id_byte;
  end else if (bus_addr[6:4] == 3'b110) begin
    bus_rdata = fifo_rdata;
  end else if (in_user) begin
    bus_rdata = reg_rdata;
  end else begin
    case (bus_addr)
      `FW2_REG_RESET:    bus_rdata = rd_rst;
      `FW2_REG_IODIR_HI: bus_rdata = iodir_hi;
      `FW2_REG_IODIR_LO: bus_rdata = iodir_lo;
      `FW2_REG_CONTENTION_GPIO: bus_rdata = {6'b000000, contention[9:8]};
      `FW2_REG_CONTENTION:      bus_rdata = contention[7:0];
      `FW2_REG_IO_ARM:   bus_rdata = {6'b000000, reset_since_arm, io_arm};
      default:           bus_rdata = 8'h00;
    endcase
  end
end

// User register window strobes (absolute addresses). While reg_rd is high,
// reg_addr carries the address of the byte that was just shifted out.
wire rd_in_user = (bus_rd_addr >= `FW2_REG_USER_FIRST) && (bus_rd_addr <= `FW2_REG_USER_LAST);
assign reg_wr   = wr_strobe & in_user;
assign reg_rd   = bus_rd_done & rd_in_user;
assign reg_addr = bus_rd_done ? bus_rd_addr : bus_addr;

// ===================== //
// ==== Stream FIFO ==== //
// ===================== //

generate
  if (HAS_STREAM) begin : g_stream
    fw2_stream_fifo
    u_fifo
    (
      .clk(CLK),
      .rst(~resetn),
      .host_addr(bus_addr[3:0]),
      .host_rdata(fifo_rdata),
      .host_wr(wr_strobe & (bus_addr[6:4] == 3'b110)),
      .host_wdata(bus_wdata),
      .host_rd_done(bus_rd_done & (bus_rd_addr[6:4] == 3'b110)),
      .host_rd_addr(bus_rd_addr[3:0]),
      .fifo_tx_data(fifo_tx_data),
      .fifo_tx_valid(fifo_tx_valid),
      .fifo_tx_ready(fifo_tx_ready),
      .fifo_rx_data(fifo_rx_data),
      .fifo_rx_valid(fifo_rx_valid),
      .fifo_rx_ready(fifo_rx_ready)
    );
  end else begin : g_nostream
    assign fifo_rdata    = 8'h00;   // status reads 0: FW2_FSTAT_PRESENT clear
    assign fifo_tx_data  = 8'h00;
    assign fifo_tx_valid = 1'b0;
    assign fifo_rx_ready = 1'b0;
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_fifo = fifo_tx_ready | fifo_rx_valid | (|fifo_rx_data);
    /* verilator lint_on UNUSEDSIGNAL */
  end
endgenerate

// =================== //
// ==== User core ==== //
// =================== //

user_core
u_user
(
  .clk(CLK),
  .rst_n(resetn),
  .hdr_in(hdr_in),
  .hdr_out(hdr_out),
  .hdr_oe(hdr_oe),
  .rp_in(rp_in),
  .rp_out(rp_out),
  .reg_addr(reg_addr),
  .reg_wdata(bus_wdata),
  .reg_wr(reg_wr),
  .reg_rd(reg_rd),
  .reg_rdata(reg_rdata),
  .fifo_tx_data(fifo_tx_data),
  .fifo_tx_valid(fifo_tx_valid),
  .fifo_tx_ready(fifo_tx_ready),
  .fifo_rx_data(fifo_rx_data),
  .fifo_rx_valid(fifo_rx_valid),
  .fifo_rx_ready(fifo_rx_ready)
);

endmodule
