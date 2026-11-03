# Getting data out of (and into) your design

Three ways to move bytes between your design and the RP2350. Each one is a
firmware command under the FPGA menu (`h\f`) and an `fwfpga stream` command,
and each needs the right modes in `design.toml`.

| Path | Direction | Rate | Firmware | CLI | Design needs |
|---|---|---|---|---|---|
| **Stream FIFO** | FPGA → host (and host → FPGA by register writes) | ~110 KB/s | `h\f\x` (≤ 256 bytes, hex), `h\f\c` (to a file) | `fwfpga stream rx <n> [-o file]` | `STREAM` capability; any profile |
| **PIO link, FPGA clock** | FPGA → RP2350 | ~15.6 MB/s in 32 KB bursts | `h\f\p` | `fwfpga stream pio <n> [-o file] [--check]` | data (GPIO8-15) and GPIO26 `LINK_F2RP` |
| **PIO link, RP2350 clock** | FPGA → RP2350, continuous | ~5.2 MB/s, any length, lossless | `h\f\k` | `fwfpga stream pio <n> --continuous [--div D]` | data `LINK_F2RP`, GPIO26 `LINK_RP2F` |
| | RP2350 → FPGA | ~5.36 MB/s | `h\f\k` | `fwfpga stream tx <n> [--div D] [--check]` | data and GPIO26 `LINK_RP2F` |

Rates include writing to or reading from the SD card. Captures land in a file
on the SD card; the CLI fetches it with a CRC check.

## Which one to use

- **A few KB at a time, or control plus data:** the stream FIFO. It works
  with any IO profile, so the header pins stay free for your design.
  Tutorial: `docs/learn/03-streaming.md`; registers: `docs/drivers/stream_fifo.md`.
- **Fast bursts:** the FPGA-clocked PIO link (`designs/pio_link`).
- **A long stream with no gaps, or data into the FPGA:** the RP2350-clocked
  link (`designs/pio_stream`, `designs/pio_sink`). The RP2350 pauses the clock
  when its buffer is full, so nothing is lost.

Tutorial for both links: `docs/learn/04-pio-link.md`.

## Limits

- The PIO links use the inner wires of the SPI, UART and GPIO26 signals,
  so those header pins are not available to the design while it streams, and
  the register bus (which shares the SPI wires) should not be used during a
  stream.
- The stream FIFO is limited by the register bus clock (at most 5 MHz at a
  31.25 MHz fabric clock).
- Register values and FIFO contents are lost if zone 6 is switched off.
