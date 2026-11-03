// fw2_regs.vh - register map constants of the FW2 shell (docs/drivers/shell.md).
// 7-bit addresses on the SPI register bus; command byte bit 7 = read.
`ifndef FW2_REGS_VH
`define FW2_REGS_VH

// Shell block 0x00-0x0F (stock-compatible where the stock has a register)
`define FW2_REG_RESET      7'h01 // write bit0=1: one-cycle synchronous reset of the whole shell, clears IO_ARM
`define FW2_REG_IODIR_HI   7'h02 // RO: stock io_buffer direction byte 1 (CTS SCK CS MISO MOSI TX RX RTS), derived from the profile
`define FW2_REG_IODIR_LO   7'h03 // RO: stock io_buffer direction byte 2 ({6'b0, GPIO26, GPIO27})
`define FW2_REG_HSBDIO     7'h04 // RO, reads 0: stock high-speed bidirectional IO is not supported (directions come only from the profile)
// Fabric readback self-check. Bit = 1: while IO_ARM=1 an FPGA_OUT
// signal's _Out pad read back a level different from the value the shell drove
// for >= 4 consecutive clocks (something on the header side is fighting the
// pad). Sticky; the byte that is read is cleared by its own read strobe; both
// bytes clear on reg 0x01 reset and on disarm, and read 0 while disarmed.
// Signals whose mode is not FPGA_OUT never set a bit. Writes are ignored.
`define FW2_REG_CONTENTION_GPIO 7'h0D // RO: {6'b0, GPIO27 (sig 9), GPIO26 (sig 8)} -- bit0 = gpio26, bit1 = gpio27 (bundle order)
`define FW2_REG_CONTENTION      7'h0E // RO: bit i = signal FW2_SIG_* i, 0 spi_miso .. 7 uart_rts (bundle order)
`define FW2_REG_IO_ARM     7'h0F // bit0 IO_ARM (RW, resets to 0), bit1 RESET_SINCE_ARM (sticky, cleared by any write to 0x0F)

// User window 0x10-0x5F (80 registers), decoded by user_core with absolute addresses
`define FW2_REG_USER_FIRST 7'h10
`define FW2_REG_USER_LAST  7'h5F

// Stream FIFO 0x60-0x6F (present when FW2_CAP_STREAM is set)
`define FW2_REG_FIFO_TX    7'h60 // WO, hold-address: host -> FPGA data push
`define FW2_REG_FIFO_RX    7'h61 // RO, hold-address: FPGA -> host data pop
`define FW2_REG_FIFO_STAT  7'h62 // RO: see FW2_FSTAT_*; sticky bits clear when this byte has been read
`define FW2_REG_FIFO_CTRL  7'h63 // WO: see FW2_FCTRL_*
`define FW2_REG_FIFO_CNT0  7'h64 // RO: RX (FPGA -> host) byte count, little endian, 0x64..0x67
`define FW2_REG_FIFO_CNT1  7'h65
`define FW2_REG_FIFO_CNT2  7'h66
`define FW2_REG_FIFO_CNT3  7'h67

`define FW2_FSTAT_RX_EMPTY   0 // no FPGA -> host data
`define FW2_FSTAT_RX_FULL    1
`define FW2_FSTAT_TX_EMPTY   2 // no host -> FPGA data waiting for the user core
`define FW2_FSTAT_TX_FULL    3
`define FW2_FSTAT_RX_OVERRUN 4 // sticky: user core pushed while RX full (byte dropped)
`define FW2_FSTAT_TX_OVERRUN 5 // sticky: host wrote 0x60 while TX full (byte dropped)
`define FW2_FSTAT_RX_UNDERRUN 6 // sticky: host read 0x61 while RX empty (0x00 returned)
`define FW2_FSTAT_PRESENT    7 // 1 when the stream FIFO is built in

`define FW2_FCTRL_RX_FLUSH   0
`define FW2_FCTRL_TX_FLUSH   1
`define FW2_FCTRL_CLR_FLAGS  2

// ID block 0x70-0x7F (read only)
`define FW2_REG_ID_BASE    7'h70
`define FW2_ID_MAGIC0      8'h46 // 'F'
`define FW2_ID_MAGIC1      8'h57 // 'W'
`define FW2_ID_MAGIC2      8'h32 // '2'
`define FW2_ID_MAGIC3      8'h46 // 'F'
`define FW2_CONTRACT_VERSION 8'd1

// Capability bits (ID block byte 0x79 and the .fwfpga header)
`define FW2_CAP_IO_BUFFER  0
`define FW2_CAP_STREAM     1
`define FW2_CAP_PSRAM_SWAP 2
`define FW2_CAP_CM0        3
`define FW2_CAP_I2C_SLAVE  4

`endif
