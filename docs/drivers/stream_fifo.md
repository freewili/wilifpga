# Stream FIFO driver notes (registers 0x60-0x6F)

Module: `fpga/lib/fw2_stream_fifo/` (`fw2_stream_fifo.v`, `fw2_fifo_sync.v`).
Present in a design only when its `capabilities` include `STREAM` (ID block
byte 0x79 bit 1); without it the whole window reads 0x00 and bit 7 of 0x62 is
0. Covered by `fpga/sim/tb_shell.v`.

Naming is from the host's (RP2350's) point of view, the same as the register
names: **TX = host -> FPGA** (register 0x60, `fifo_tx_*` ports into the user
core), **RX = FPGA -> host** (register 0x61, `fifo_rx_*` ports out of the user
core).

## Registers

| addr | R/W | burst | contents |
|---|---|---|---|
| 0x60 | W | hold-address | TX data: every data byte of the transaction is pushed into the 256-byte TX FIFO. Dropped (and `TX_OVERRUN` set) when full. |
| 0x61 | R | hold-address | RX data: every data byte pops one byte from the 4096-byte RX FIFO. Reading while empty returns 0x00 and sets `RX_UNDERRUN`. |
| 0x62 | R | auto-inc | status: bit 0 `RX_EMPTY`, 1 `RX_FULL`, 2 `TX_EMPTY`, 3 `TX_FULL`, 4 `RX_OVERRUN` (user core pushed while full; byte dropped), 5 `TX_OVERRUN`, 6 `RX_UNDERRUN`, 7 `PRESENT` = 1. Bits 4-6 are sticky and clear after this byte has been read (or via 0x63 bit 2). |
| 0x63 | W | auto-inc | control: bit 0 flush RX, bit 1 flush TX, bit 2 clear sticky flags. Self-clearing strobes. |
| 0x64-0x67 | R | auto-inc | RX byte count, little endian (0..4096). A 4-byte read from 0x64 returns it in one transaction. |
| 0x68-0x6F | R | | reserved, 0x00. |

## Host sequence (what `h\f\x` / `fwfpga stream rx` should do)

1. Inside one IO_CONFIG_ENABLE window: read 0x64..0x67 (4 bytes, one
   transaction) to get `n`.
2. Burst-read `min(n, chunk)` bytes with a single command byte `0xE1`
   (`0x80 | 0x61`) followed by `min(n, chunk)` clocked bytes; CS low throughout.
   The address holds at 0x61 for the whole burst (`fw2_spi_slave` `hold`).
   DMA'd SPI1 with CS as a GPIO works unchanged.
3. Read 0x62 once per chunk to catch `RX_OVERRUN` (data loss inside the FPGA)
   and `RX_UNDERRUN` (the host read more than was there).
4. Keep SCK <= 5 MHz at a 31.25 MHz fabric clock (`docs/drivers/shell.md`
   section 1); 3.25 MHz gives about 400 KB/s raw, 5 MHz about 620 KB/s.

Host -> FPGA: burst-write with command byte `0x60` then the data bytes; check
`TX_FULL`/`TX_OVERRUN` in 0x62 if the user core may be slower than the bus.

## Timing inside the fabric

* RX pop happens on the `rd_done` strobe of the byte that was just shifted out
  (two fabric clocks after its 8th SCK rising edge). `fw2_fifo_sync` fetches
  `mem[next rd_ptr]` with a combinational address, so the next head is on
  `rdata` one clock after the pop, about 1-2 clocks before the SPI slave loads
  it at the following SCK falling edge at 5 MHz SCK. This is the path that sets
  the SCK ceiling together with the slave's own pipeline.
* A push into an empty FIFO is visible to the reader two clocks later
  (read-before-write in the EBR); `valid` masks the gap so the host never sees
  a stale byte, and `RX_EMPTY`/the count tell the host when data is there.
* The user side is plain valid/ready: `fifo_rx_valid & fifo_rx_ready` pushes one
  byte per clock; a core that pushes while `fifo_rx_ready` is low loses that
  byte and sets `RX_OVERRUN`. Decide on the current cycle's `ready`: a core
  that samples `ready` and asserts `valid` one clock later can hit a FIFO that
  filled in between (`logic_capture` holds the sample until accepted). `fifo_tx_ready` pops the byte on `fifo_tx_data`
  when `fifo_tx_valid` is high.

## Resources

4096-byte RX (8 EBR) + 256-byte TX (1 EBR) = 9 of the UP5K's 30 EBRs, about 90
LUTs.

## Rate

`fwfpga stream rx` moves about 110 KB/s from the FIFO to the SD card. The
limit is the register bus clock (at most 5 MHz at a 31.25 MHz fabric clock).
For more, use the PIO link (`docs/learn/04-pio-link.md`).
