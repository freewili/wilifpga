# Third-party notices

Most of this repository was written for the FreeWili 2 FPGA BSP. The files
below come from, or are derived from, the FreeWili 2 stock FPGA gateware
(repository `freewilifpga`) and are published here with FreeWili's permission.
Each file carries its provenance and original authors in its header.

| File | Relation to the stock gateware | Original authors |
|---|---|---|
| `fpga/lib/spi_slave/spi_slave.v` | verbatim copy of `fpga/src/dsn/spi_slave.v` | Adam Kidwell, Jason Rosenkranz |
| `fpga/shell/fw2_spi_slave.v` | derived from `fpga/src/dsn/fw_spi_slave.v` (hold-address bursts, read strobe, width fixes) | Adam Kidwell |
| `fpga/shell/fw2_rst_ctrl_reg.v` | derived from `fpga/src/dsn/rst_ctrl_reg.v` (self-clearing reset request) | Jason Rosenkranz |
| `fpga/shell/fw2_io_buffer.v` | rewrite of `fpga/src/dsn/io_buffer.v`, keeping its pad pairing and direction polarity | Adam Kidwell (original) |
| `fpga/constraints/fw2.pcf` | copy of the stock pin constraints (`fw.pcf` in the stock repository) | FreeWili |

These files are covered by the repository's [FreeWili 2 Hardware License](LICENSE).

The open-source FPGA toolchain (yosys, nextpnr, icestorm, iverilog, verilator)
is not part of this repository; `tools/fwfpga.py` downloads the YosysHQ
oss-cad-suite, which carries its own licences.
