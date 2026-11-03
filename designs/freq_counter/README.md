# freq_counter

Rising-edge counters on three header inputs (UART1 RX, UART1 CTS, GPIO26 as
`FPGA_IN`), free-running or with a 1 s gate (then the registers read Hz), plus
a 1 kHz test square wave on GPIO27 (`FPGA_OUT`) so a header jumper 27 -> 26
proves the counter with no external equipment.

## What you learn

Inputs: `FPGA_IN` (shifter toward board, FPGA pad input), synchronisers before
counting an asynchronous edge, 24-bit counters read as three bytes, and why a
multi-byte snapshot must be frozen while the host bursts it out (the `reg_rd`
strobe).

## Build & load

```sh
tools/fwfpga build freq_counter
tools/fwfpga sim freq_counter
tools/fwfpga install freq_counter
tools/fwfpga load freq_counter
```

The testbench jumpers GPIO27 to GPIO26, feeds 250 kHz into UART RX, and
shrinks the gate to 10 ms through the `GATE_CLOCKS` parameter (1 kHz -> 10,
250 kHz -> 2500 per gate).

## Verify

Jumper header GPIO27 to GPIO26 (an LED on GPIO27 glows at half brightness:
1 kHz). `fwfpga reg w 0x21 0x01` (gate mode), wait > 1 s, read
0x16..0x18: `E8 03 00` = 1000 Hz. Drive UART CTS (GPIO10) from the RP2350 with
`i\g\s 10` / `i\g\l 10` toggles and watch 0x13..0x15 grow in free-running mode
(`0x21 = 0`, `0x20 = 0x02` clears). Cross-check: RP2350 PWM on GPIO25 is not
visible to the FPGA (GPIO25 bypasses it); use GPIO27's own 1 kHz instead.

## Pins used

| signal | mode | role |
|---|---|---|
| UART RX (GPIO9) | `FPGA_IN` | counter 0 (0x10-0x12) |
| UART CTS (GPIO10) | `FPGA_IN` | counter 1 (0x13-0x15) |
| GPIO26 | `FPGA_IN` | counter 2 (0x16-0x18) |
| GPIO27 | `FPGA_OUT` | 1 kHz test output |
| SPI MISO | `PASS_IN` | stock passthrough |
| SPI CS/SCLK/MOSI, UART TX, UART RTS | `PASS_OUT` | stock passthrough |

## Registers

| addr | R/W | contents |
|---|---|---|
| 0x10-0x12 | R | UART RX rising-edge count, 24-bit little endian (snapshot) |
| 0x13-0x15 | R | UART CTS count |
| 0x16-0x18 | R | GPIO26 count |
| 0x20 | W | bit 0 latch live -> snapshot (free-running mode); bit 1 clear live counters |
| 0x21 | RW | 0 = free running (snapshot follows live except during a 3-byte burst), 1 = 1 s gate (snapshot <= live, live <= 0 every 31 250 000 clocks). Writing it clears the counters and restarts the gate. |
| 0x22 | R | bit 0 = a gate result landed since the last read of 0x22 (clears on read); bit 1 = GPIO27 test level |

Snapshot rule: a counter's three bytes are frozen from the `reg_rd` of its
first byte to the `reg_rd` of its third, so a burst read is self-consistent.
