# pio_sink: RP2350 → FPGA link checker

**What you learn:** the `LINK_RP2F` profile mode in the data direction. The
RP2350 drives the RP side of eight header signals and the FPGA reads them on
its inner nets while the header stays isolated. The RP2350's PIO puts a byte
on GPIO8-15 while the link clock (GPIO26) is low, then raises the clock. If
its FIFO runs dry it stalls with the clock low, so the FPGA never sees a
partial or repeated byte.

The core passes clock and data through identical two-flop synchronisers. On
each rising edge it takes the byte, checks it equals the previous byte + 1,
and counts bytes and errors. The firmware command *Link Stream*
(`h\f\k count - div`) sends a repeating 00..FF counter by DMA from SRAM.

## Build

```
fwfpga build pio_sink      # ~375 LCs, meets 31.25 MHz
fwfpga sim pio_sink        # 1000 bytes, 0 errors across a stall; a skip counts 1
```

## Install & load

```
fwfpga install pio_sink
fwfpga load pio_sink       # design_id 9 ... cdone 1
```

## Verify

```
fwfpga stream tx 8388608 --div 1 --check
```

Expect `FPGA (pio_sink): 8388608 bytes received, 0 pattern errors`. Rate
by PIO divider:

| PIO divider | Rate |
|---|---|
| 8 | 0.67 MB/s |
| 4 | 1.34 MB/s |
| 2 | 2.68 MB/s |
| 1 | 5.36 MB/s |

## Pins used

GPIO8-15 and GPIO26 inner nets, all `LINK_RP2F` (the RP2350 drives them).
GPIO27 passthrough. The header is isolated while this design is armed.

## Registers

| Addr | R/W | Meaning |
|---|---|---|
| 0x10 | W | write bit0 = 1: clear counts |
| 0x11..0x14 | RO | bytes received since clear, u32 LE |
| 0x15..0x18 | RO | pattern errors since clear, u32 LE |
| 0x19 | RO | last byte received |
| 0x1A | RO | first byte received since clear |
