// fw2_design_id.vh - ID block constants for design 'hello_regs'.
// HAND-WRITTEN placeholder consistent with design.toml; tools/gen_design_id.py
// regenerates this file into the build directory from design.toml.
// ID block bytes 0x70..0x7F: 46 57 32 46 01 03 00 01 00 01 00 01 80 04 12 F0
`ifndef FW2_DESIGN_ID_VH
`define FW2_DESIGN_ID_VH
`define FW2_DESIGN_ID         16'd3
`define FW2_DESIGN_VERSION    16'd1
`define FW2_DESIGN_CAPS       8'h01
`define FW2_DESIGN_CLOCK_CODE 8'd0
`define FW2_DESIGN_CLOCK_HZ   31250000
`define FW2_DESIGN_IO_PROFILE 32'h12048001
`define FW2_DESIGN_CHECKSUM   8'hF0
`define FW2_IOP_SPI_MISO  3'd1 // PASS_IN
`define FW2_IOP_SPI_CS    3'd0 // PASS_OUT
`define FW2_IOP_SPI_SCLK  3'd0 // PASS_OUT
`define FW2_IOP_SPI_MOSI  3'd0 // PASS_OUT
`define FW2_IOP_UART_TX   3'd0 // PASS_OUT
`define FW2_IOP_UART_RX   3'd1 // PASS_IN
`define FW2_IOP_UART_CTS  3'd1 // PASS_IN
`define FW2_IOP_UART_RTS  3'd0 // PASS_OUT
`define FW2_IOP_GPIO26    3'd2 // FPGA_OUT
`define FW2_IOP_GPIO27    3'd2 // FPGA_OUT
`endif
