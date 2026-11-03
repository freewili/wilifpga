// ---------------------------------------------------------------------------
// spi_bus_bfm.v - bus-functional model of the MAIN RP2350's SPI register
// master as fwProgIODir drives it: SPI mode 0 (CPOL=0, CPHA=0), 8-bit frames,
// MSB first, CS as a GPIO held low for the whole transaction, command byte
// bit7 = read, bits[6:0] = address, then data bytes. Default SCK = 3.25 MHz.
// Also models the IO_CONFIG_ENABLE line (io_config_en task).
// New code, FreeWili 2 FPGA BSP, 2026.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module spi_bus_bfm
#
(
  parameter real HALF_NS     = 153.8,  // half SCK period (3.25 MHz)
  parameter real BYTE_GAP_NS = 0.0,    // idle time between bytes (CS stays low)
  parameter integer BUF_SIZE = 8192
)
(
  output reg sclk,
  output reg mosi,
  input  wire miso,
  output reg cs,
  output reg io_cfg_en
);

reg [7:0] rx_buf [0:BUF_SIZE-1];   // filled by burst_read
reg [7:0] tx_buf [0:BUF_SIZE-1];   // consumed by burst_write
integer   bytes_moved;

initial begin
  sclk = 1'b0;
  mosi = 1'b0;
  cs   = 1'b1;
  io_cfg_en = 1'b0;
end

// Release every bus line (Z) so the testbench can check pad tri-states
task release_bus;
begin
  sclk = 1'bz;
  mosi = 1'bz;
  cs   = 1'bz;
end
endtask

// Re-take the bus idle (CS high, SCK low)
task hold_bus;
begin
  sclk = 1'b0;
  mosi = 1'b0;
  cs   = 1'b1;
end
endtask

task io_config_en(input level);
begin
  io_cfg_en = level;
  #(4*HALF_NS);
end
endtask

task xfer_byte(input [7:0] tx, output [7:0] rx);
  integer b;
begin
  for (b = 7; b >= 0; b = b - 1) begin
    mosi = tx[b];
    #(HALF_NS);
    sclk = 1'b1;          // slave samples MOSI, master samples MISO
    rx[b] = miso;
    #(HALF_NS);
    sclk = 1'b0;          // slave presents the next MISO bit
  end
  if (BYTE_GAP_NS > 0.0) #(BYTE_GAP_NS);
end
endtask

task start_txn(input [7:0] cmd);
  reg [7:0] dummy;
begin
  hold_bus;
  cs = 1'b0;
  #(HALF_NS);
  xfer_byte(cmd, dummy);
end
endtask

task end_txn;
begin
  #(HALF_NS);
  cs = 1'b1;
  #(4*HALF_NS);
end
endtask

task reg_write(input [6:0] addr, input [7:0] data);
  reg [7:0] dummy;
begin
  start_txn({1'b0, addr});
  xfer_byte(data, dummy);
  end_txn;
end
endtask

task reg_read(input [6:0] addr, output [7:0] data);
begin
  start_txn({1'b1, addr});
  xfer_byte(8'h00, data);
  end_txn;
end
endtask

// n bytes into rx_buf[0..n-1]; address semantics (hold vs increment) are the shell's
task burst_read(input [6:0] addr, input integer n);
  integer i;
  reg [7:0] d;
begin
  start_txn({1'b1, addr});
  for (i = 0; i < n; i = i + 1) begin
    xfer_byte(8'h00, d);
    rx_buf[i] = d;
  end
  end_txn;
  bytes_moved = n;
end
endtask

// n bytes from tx_buf[0..n-1]
task burst_write(input [6:0] addr, input integer n);
  integer i;
  reg [7:0] dummy;
begin
  start_txn({1'b0, addr});
  for (i = 0; i < n; i = i + 1) begin
    xfer_byte(tx_buf[i], dummy);
  end
  end_txn;
  bytes_moved = n;
end
endtask

endmodule
