# pio_link — T2 parallel link (FPGA → RP2350 over the inner nets)

**What you learn:** the `LINK_F2RP` profile mode (the FPGA drives the RP2350
side of a header signal while the header itself stays isolated), how a byte is
laid out across GPIO8-15 so MAIN's PIO can read it with one `in pins, 8`, and
how a sampled link clock (GPIO26) moves data an order of magnitude faster than
the register bus.

The core is a free-running 8-bit counter presented on the eight shifter
signals, with a link clock on GPIO26 at `clk / 2^(div+1)` (15.6 MHz by
default). Data changes on the falling edge; MAIN samples on the rising edge.
The firmware command *PIO Link Capture* (`h\f\p count path`) programs PIO1
with a three-instruction sampler, DMA-fills a PSRAM buffer, writes it to the
SD card and reports bytes and milliseconds; `fwfpga stream pio N -o file`
fetches it, and because the pattern is a counter the host can verify every
byte.

## Build

```
fwfpga build pio_link      # must meet 31.25 MHz
fwfpga sim pio_link        # counter consecutive on the link clock, hold works
```

## Install & load

```
fwfpga install pio_link
fwfpga load pio_link       # design_id 7 ... cdone 1
```

## Verify

```
fwfpga stream pio 65536 -o link.bin    # capture 64 KB through PIO1 + DMA
python -c "d=open('link.bin','rb').read(); print(all((d[i+1]-d[i])%256==1 for i in range(len(d)-1)))"
```

Expect `True` and a device-reported rate around 15 MB/s at the default
divider. Nothing changes on the header pins: the header is isolated in
LINK mode (shifters toward the board, `_Out` pads Z). Set register 0x12 to
slow the link clock (1 = clk/4, …) and 0x10 bit1 to freeze the counter.

## Pins used

GPIO8-15 and GPIO26 inner nets only (`LINK_F2RP`); GPIO27 passthrough. The
header pins 5/7/9/11/12/13/14/15 carry nothing while this design is armed.

## Registers

| Addr | R/W | Meaning |
|---|---|---|
| 0x10 | RW | control: bit0 run (default 1), bit1 hold |
| 0x11 | RO | current counter value |
| 0x12 | RW | link clock divider 0..7 (half-period = 2^div clocks; 0 = 15.6 MHz) |
