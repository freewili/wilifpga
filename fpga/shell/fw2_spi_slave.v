// ---------------------------------------------------------------------------
// PROVENANCE: derived from fw_spi_slave.v of the FreeWili stock gateware
// repository "freewilifpga" (fpga/src/dsn/fw_spi_slave.v, snapshot 2026-10-31,
// authored by Adam Kidwell). Local changes (FW2 shell):
//   1. `hold` input: while high the address does not auto-increment after a
//      data byte, giving the stream FIFO registers 0x60/0x61 hold-address
//      bursts. Writes still get their first increment (the stock pre-decrement
//      must be undone), reads hold from the first data byte.
//   2. `rd_done` / `rd_done_addr` outputs: one-cycle strobe after each data
//      byte of a READ transaction, with the address of the byte that was just
//      shifted out (the stock core exposes no read strobe).
//   3. Reset widths fixed (7-bit addr), wire declarations tidied for lint.
// Bus semantics otherwise unchanged: command byte bit7 = read, bits[6:0] =
// address; data byte k of a transaction addresses cmd_addr + k - 1 for both
// reads and writes (see docs/drivers/shell.md).
// ---------------------------------------------------------------------------

module fw2_spi_slave
(
  input  wire       clk,
  input  wire       resetn,
  // External SPI signals
  output wire       spi_miso,
  input  wire       spi_mosi,
  input  wire       spi_cs,
  input  wire       spi_sck,
  // Internal FPGA signals
  input  wire       en,
  input  wire       hold,         // 1: do not auto-increment addr after this data byte
  output reg        wr,           // 1 for the whole of a write transaction
  output reg  [6:0] addr,         // Address the next data byte applies to
  output reg  [7:0] wr_data,      // The data following the command
  output reg        data_valid,   // One-cycle strobe: wr_data landed at addr (write) / a byte was shifted out (read)
  output reg        rd_done,      // One-cycle strobe per data byte of a read transaction
  output reg  [6:0] rd_done_addr, // Address of the byte reported by rd_done
  input  wire [7:0] rd_data
);

wire [7:0] rx_byte;          // Last completed byte from the core
wire       rx_byte_valid;    // One-cycle strobe per completed byte
wire       rx_first;         // High for the command byte
/* verilator lint_off UNUSEDSIGNAL */
wire       cs_active;        // Not used by the register bus
/* verilator lint_on UNUSEDSIGNAL */

reg        rd         = 1'b0; // When asserted, initiates MISO data transmission
reg        first_data = 1'b0; // 1 until the first data byte after the command has been handled
reg        data_valid_latch = 1'b0;

spi_slave
spi_slave_inst
(
  .clk(clk),
  .resetn(resetn),
  .spi_miso(spi_miso),
  .spi_mosi(spi_mosi),
  .spi_cs(spi_cs),
  .spi_sck(spi_sck),
  .en(en),
  .rx_byte(rx_byte),
  .rx_byte_valid(rx_byte_valid),
  .rx_first(rx_first),
  .cs_active(cs_active),
  .tx_data(rd_data),
  .tx_en(rd)
);

// Process for parsing the command byte and driving the internal register bus.
always @(posedge clk)
begin
  if (resetn == 1'b1) begin
    rd_done <= 1'b0;
    if (rx_byte_valid == 1'b1) begin
      if (rx_first == 1'b1) begin
        // Command byte: bit7 = read. Reads address cmd directly. Writes
        // pre-decrement so the first data byte, after the increment below,
        // lands at cmd (stock behaviour, kept so the firmware's register
        // access sequences work unchanged).
        wr         <= ~rx_byte[7];
        rd         <=  rx_byte[7];
        first_data <= 1'b1;
        if (rx_byte[7] == 1'b1) begin
          addr <= rx_byte[6:0];
        end else begin
          addr <= rx_byte[6:0] - 7'd1;
        end
      end else begin
        wr_data <= rx_byte;
        if (data_valid_latch == 1'b0) begin
          data_valid_latch <= 1'b1;
          data_valid       <= 1'b1;
          first_data       <= 1'b0;
          // Auto-increment unless held. A write's first data byte always
          // increments (undoing the pre-decrement); a read holds from byte 1.
          if (!(hold && (rd || !first_data))) begin
            addr <= addr + 7'd1;
          end
          if (rd) begin
            rd_done      <= 1'b1;
            rd_done_addr <= addr;
          end
        end else begin
          data_valid <= 1'b0;
        end
      end
    end else begin
      data_valid_latch <= 1'b0;
      data_valid       <= 1'b0;
    end
  end else begin
    wr               <= 1'b0;
    rd               <= 1'b0;
    wr_data          <= 8'h00;
    data_valid_latch <= 1'b0;
    data_valid       <= 1'b0;
    first_data       <= 1'b0;
    addr             <= 7'h00;
    rd_done          <= 1'b0;
    rd_done_addr     <= 7'h00;
  end
end

endmodule
