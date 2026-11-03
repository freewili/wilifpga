# Learn 03 — Streaming: the stream FIFO

**What you learn.** How a design sends bytes to the host faster than one
register read per byte, using the shell's FIFO.

**You need.** Tutorials 01-02.

## 1. Enable the FIFO

```toml
capabilities = ["IO_BUFFER", "STREAM"]
```

With `STREAM` the shell adds a **4096-byte RX FIFO** (FPGA → host) and a
**256-byte TX FIFO** (host → FPGA), using 9 of the 30 block RAMs. Names are
from the host's side: RX is what the host receives.

## 2. Your side

Valid/ready, one byte per clock:

```verilog
// FPGA -> host
assign fifo_rx_data  = sample;
assign fifo_rx_valid = sample_ready;     // taken when fifo_rx_ready is high
// host -> FPGA
assign fifo_tx_ready = want_byte;        // takes fifo_tx_data when fifo_tx_valid is high
```

A push while `fifo_rx_ready` is low loses the byte and sets `RX_OVERRUN`.

## 3. The host side

```sh
tools/fwfpga stream rx 256              # up to 256 bytes, printed as hex
tools/fwfpga stream rx 65536 -o cap.bin # larger: the firmware writes the SD card, the CLI fetches the file
```

Expect about 110 KB/s. Registers, if you need them directly (full table in
`docs/drivers/stream_fifo.md`):

| addr | contents |
|---|---|
| 0x60 | TX data (write; every byte of a burst goes into the FIFO) |
| 0x61 | RX data (read; every byte of a burst pops one) |
| 0x62 | status: empty/full flags, sticky `RX_OVERRUN` / `TX_OVERRUN` / `RX_UNDERRUN`, bit 7 = FIFO present |
| 0x63 | control: flush RX, flush TX, clear flags |
| 0x64-0x67 | RX byte count |

## 4. Example

`designs/logic_capture` samples eight header pins into the RX FIFO at a rate
set by register 0x10.

## What can go wrong

- **0x62 bit 7 is 0:** the design was built without `STREAM`.
- **`RX_OVERRUN`:** your core produced faster than the host read; slow the
  producer or read in larger bursts.
- **`idblock:caps` on load:** `STREAM` is in the core but not in
  `design.toml`, or the other way round.

For more than ~110 KB/s use the PIO link: `04-pio-link.md`.
