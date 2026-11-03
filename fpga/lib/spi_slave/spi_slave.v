// ---------------------------------------------------------------------------
// PROVENANCE: harvested from the FreeWili stock gateware repository
// "freewilifpga", file fpga/src/dsn/spi_slave.v, snapshot taken 2026-10-31
// (tree at commit 1da6e9f, source files dated 2026-07-22).
// Original authors are credited in the comments below. Licence: as the
// source repository (see THIRD-PARTY-NOTICES.md).
// Local changes: none.
// ---------------------------------------------------------------------------
// SPI Slave component created for FREE WILi project
// Authored by Adam Kidwell and Jason Rosenkranz

module spi_slave
(
  input            clk,
  input            resetn,
  // External SPI signals
  output reg       spi_miso,
  input            spi_mosi,
  input            spi_cs,
  input            spi_sck,
  // Internal FPGA signals
  input            en,
  output reg [7:0] rx_byte,        // Last completed received byte
  output reg       rx_byte_valid,  // One-cycle strobe per completed byte
  output reg       rx_first,       // High for the first byte after CS assert
  output reg       cs_active,      // High while CS is asserted (synchronized)
  input      [7:0] tx_data,        // Byte to shift out on MISO
  input            tx_en           // Drive MISO from tx_data
);

reg       rising_edge_sck;   // Flag tracking when we have an SCK rising edge for latching input data
reg       falling_edge_sck;  // Flag tracking when we have an SCK falling edge for latching output data
reg       cs_sync_0;         // First synchronizer stage for CS
reg       cs_sync_1;         // Second synchronizer stage for CS
reg       sck_sync_0;        // First synchronizer stage for SCK
reg       sck_sync_1;        // Second synchronizer stage for SCK
reg       mosi_reg;          // Registered MOSI input for clock domain crossing

reg [7:0] mosi_sreg;         // Shift register for bringing in MOSI data
reg [7:0] miso_sreg;         // Shift register for outputting MISO data
reg [3:0] bit_counter;       // Count how many bits we have received to create a byte
reg       first_byte;        // Flag for tracking when we are on the first byte after CS assert

// Registers grabbing MOSI, CS, SCK, and tracking SCK edges
always @(posedge clk)
begin
  mosi_reg   <= spi_mosi;
  cs_sync_0  <= spi_cs;
  cs_sync_1  <= cs_sync_0;
  sck_sync_0 <= spi_sck;
  sck_sync_1 <= sck_sync_0;
  if (sck_sync_1 == 1'b0 && sck_sync_0 == 1'b1) begin
    rising_edge_sck <= 1'b1;
  end else begin
    rising_edge_sck <= 1'b0;
  end
  if (sck_sync_1 == 1'b1 && sck_sync_0 == 1'b0) begin
    falling_edge_sck <= 1'b1;
  end else begin
    falling_edge_sck <= 1'b0;
  end
end

// Process for handling data in (MOSI)
always @(posedge clk)
begin
  if (resetn == 1'b0 || en == 1'b0) begin
    mosi_sreg   <= 8'b00000000;
    bit_counter <= 4'b0000;
    first_byte  <= 1'b1;
  end else begin
    // Only shift in data when CS is cleared and we have an SCK rising edge
    if (cs_sync_1 == 1'b0) begin
      if (rising_edge_sck == 1'b1) begin
        // Shift in the data
        mosi_sreg <= {mosi_sreg[6:0], mosi_reg};

        // Handle the bit counter
        if (bit_counter >= 4'b1000) begin  // If 8 bits have been shifted in...
          first_byte  <= 1'b0;             // No longer on the first byte after the first 8 bits
          bit_counter <= 4'b0001;          // Reset the bit counter
        end else begin
          bit_counter <= bit_counter + 1;  // If 8 bits have not been received, increment the bit counter
        end
      end
    end else begin                         // When CS is set, reset control signals
      mosi_sreg   <= 8'b00000000;
      bit_counter <= 4'b0000;
      first_byte  <= 1'b1;
    end
  end
end

// Process for presenting the assembled byte
always @(*)
begin
  rx_byte       = mosi_sreg;
  rx_first      = first_byte;
  cs_active     = ~cs_sync_1;
end

// One-cycle strobe as the eighth bit is shifted in, aligned with rx_byte
always @(posedge clk)
begin
  if (resetn == 1'b0 || en == 1'b0) begin
    rx_byte_valid <= 1'b0;
  end else begin
    rx_byte_valid <= (cs_sync_1 == 1'b0) & rising_edge_sck & (bit_counter == 4'b0111);
  end
end

// Process for handling data out (MISO)
// tx_data will always be populated with
// the data for the current byte.
always @(posedge clk)
begin
  // If a transmit has been initiated
  if (tx_en == 1'b1 && resetn == 1'b1) begin
    // Shift out MISO data on the
    // falling edge of SCK
    if (falling_edge_sck == 1'b1) begin
      spi_miso  <= miso_sreg[7];
      miso_sreg <= {miso_sreg[6:0], 1'b0};
      // At the end of a byte, shift in more data
      if (bit_counter == 4'b1000) begin
        miso_sreg <= {tx_data[6:0], 1'b0};
        spi_miso  <= tx_data[7];
      end
    end
  end else begin
    spi_miso  <= 1'b0;
    miso_sreg <= 8'h00;
  end
end

endmodule
