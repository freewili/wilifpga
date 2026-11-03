# pio_stream: continuous, lossless FPGA → RP2350 stream

**What you learn:** how to make a link lossless with back-pressure by letting
the *receiver* own the clock. The RP2350's PIO drives the link clock on
GPIO26 (`LINK_RP2F`) and samples GPIO8-15 (`LINK_F2RP`) as it drives the
clock low. When its buffer is full, because the SD card is still writing the
previous half, the PIO stalls with the clock low. The FPGA sees no edge and
waits, so no byte is ever dropped.

The core synchronises the link clock into its 31.25 MHz domain and advances
an 8-bit counter on every falling edge. The firmware command *Link Stream*
(`h\f\k count path div`) double-buffers two 16 KB SRAM halves: while one half
is written to the SD card the PIO fills the other. The file is one unbroken
counter, which the host verifies end to end.

Compare with `pio_link`: there the FPGA owns the clock and runs at 15.6 MB/s,
but captures are limited to 32 KB bursts with gaps between them.

## Build

```
fwfpga build pio_stream    # ~240 LCs, meets 31.25 MHz
fwfpga sim pio_stream      # consecutive samples across a 20 us clock stall
```

## Install & load

```
fwfpga install pio_stream
fwfpga load pio_stream     # design_id 8 ... cdone 1
```

## Verify

```
fwfpga stream pio 8388608 --continuous --div 1 --check -o stream.bin
```

Expect `pattern ok: one unbroken 8-bit counter across all 8388608 bytes`.
Rate by PIO divider, including SD writes:

| PIO divider | Rate |
|---|---|
| 8 | 0.67 MB/s |
| 4 | 1.34 MB/s |
| 2 | 2.63 MB/s |
| 1 | 5.2 MB/s |

Nothing changes on the header pins: the header is isolated in LINK mode.

The edge count (0x12) ends 36 above the bytes captured. After the DMA takes
its last word the PIO keeps clocking until its FIFO (8 words) and shift
register (4 bytes) are full, then the firmware disables it. Those bytes are
discarded, so the next run starts 36 counts further on.

## Pins used

GPIO8-15 inner nets (`LINK_F2RP`) and GPIO26 inner net (`LINK_RP2F`, the
RP2350 drives the clock). GPIO27 passthrough. Header pins
5/7/9/11/12/13/14/15 carry nothing while this design is armed.

## Registers

| Addr | R/W | Meaning |
|---|---|---|
| 0x10 | RW | bit0 run (default 1); write bit1 = 1 to reset counter and edge count |
| 0x11 | RO | current counter value |
| 0x12..0x15 | RO | falling edges seen since reset, u32 LE |
