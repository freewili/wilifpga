# spi_slave

Generic SPI mode-0 slave, MSB first, 8-bit frames: two-stage synchronisers on CS and SCK, samples MOSI on the SCK rising edge, shifts MISO on the falling edge, loads `tx_data` into the output shift register at the end of every byte (`bit_counter == 8`). `rx_byte_valid` is a one-clock strobe per completed byte, `rx_first` marks the command byte. The sampling scheme limits SCK to about fabric_clk/6 (5 MHz at 31.25 MHz, confirmed in tb_shell).

**Ports:** `clk, resetn, spi_miso, spi_mosi, spi_cs, spi_sck, en, rx_byte[7:0], rx_byte_valid, rx_first, cs_active, tx_data[7:0], tx_en`.

**Register addresses owned:** none.

**Status:** used by `fw2_shell` (through `fw2_spi_slave`). Provenance: FreeWili stock gateware repository `freewilifpga`, `fpga/src/dsn/spi_slave.v`, snapshot 2026-10-31 (header in the file).
