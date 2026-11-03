// fw2_profile.vh - IO profile mode codes and header-signal indices (FW2 FPGA
// design contract, docs/fwfpga-format.md). Shared by fw2_shell, the testbenches and
// the generated fw2_design_id.vh. Keep in step with tools/profile.py.
`ifndef FW2_PROFILE_VH
`define FW2_PROFILE_VH

// One 3-bit mode per header signal. Column meaning (docs/fwfpga-format.md):
//            RP2350 pin | FPGA _Rp pad | FPGA _Out pad          | shifter DIR
`define FW2_MODE_PASS_OUT  3'd0 // output | input  | output (= _Rp)       | toward header
`define FW2_MODE_PASS_IN   3'd1 // input  | output (= _Out) | input      | toward board
`define FW2_MODE_FPGA_OUT  3'd2 // input  | Z      | output (user core)   | toward header
`define FW2_MODE_FPGA_IN   3'd3 // input  | Z      | input  (user core)   | toward board
`define FW2_MODE_LINK_RP2F 3'd4 // output | input (user core) | Z         | toward board
`define FW2_MODE_LINK_F2RP 3'd5 // input  | output (user core) | Z        | toward board
`define FW2_MODE_OFF       3'd6 // input  | Z      | Z                    | toward board

// Signal indices in every 10-bit bundle (hdr_*, rp_*) and in the packed
// 30-bit profile word (signal i occupies bits [3*i+2 : 3*i]).
`define FW2_SIG_SPI_MISO 0
`define FW2_SIG_SPI_CS   1
`define FW2_SIG_SPI_SCLK 2
`define FW2_SIG_SPI_MOSI 3
`define FW2_SIG_UART_TX  4
`define FW2_SIG_UART_RX  5
`define FW2_SIG_UART_CTS 6
`define FW2_SIG_UART_RTS 7
`define FW2_SIG_GPIO26   8
`define FW2_SIG_GPIO27   9

// Pack the ten per-signal defines of fw2_design_id.vh into the 30-bit word.
`define FW2_PACK_PROFILE {`FW2_IOP_GPIO27, `FW2_IOP_GPIO26, `FW2_IOP_UART_RTS, `FW2_IOP_UART_CTS, \
                          `FW2_IOP_UART_RX, `FW2_IOP_UART_TX, `FW2_IOP_SPI_MOSI, `FW2_IOP_SPI_SCLK, \
                          `FW2_IOP_SPI_CS, `FW2_IOP_SPI_MISO}

`endif
