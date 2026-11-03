# hello_blink

A heartbeat on header pin **GPIO26**, about 2 Hz by default, rate set by
register 0x10. It is the first design to try: when it blinks on the header
through the loader, the whole chain (container, loader, ID block, arm,
profile) works.

## What you learn

Your first bitfile; what `FPGA_OUT` means (the FPGA, not the RP2350, drives a
header pin, so the shifter DIR for GPIO26 points toward the header and the
RP2350 pin must be an input); how the 31.25 MHz `FPGA_CLK` turns into human
time (2^20 clocks = 33.6 ms); how a register changes behaviour at run time.

## Build & load

```sh
tools/fwfpga build hello_blink
tools/fwfpga sim hello_blink
tools/fwfpga install hello_blink
tools/fwfpga load hello_blink
```

The testbench measures the half period at rate 0 (1 048 576 clocks) and rate 2 (3 145 728
clocks) and prints the default rate: 7 -> 1.86 Hz.

## Verify

Header GPIO26 must toggle (an LED, meter or logic analyzer on the pin) and
no other header pin may change. `fwfpga reg w 0x10 0x00` speeds the
blink up to about 15 Hz, `0x3F` slows it to about 0.23 Hz; `fwfpga reg r 0x11`
returns the current level in bit 0. `fwfpga restore` brings stock back and the
LED stops.

## Pins used

| signal | mode |
|---|---|
| GPIO26 | `FPGA_OUT` (heartbeat) |
| SPI MISO, UART RX, UART CTS | `PASS_IN` |
| SPI CS/SCLK/MOSI, UART TX/RTS, GPIO27 | `PASS_OUT` |

## Registers

| addr | R/W | contents |
|---|---|---|
| 0x10 | RW | blink rate: half period = (value + 1) x 2^20 clocks; default 7 (~1.9 Hz at 31.25 MHz) |
| 0x11 | R | bit 0 = current GPIO26 level |
