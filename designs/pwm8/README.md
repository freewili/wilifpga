# pwm8

Eight independent PWM channels on the eight shifter-driven header signals
(SPI1 MISO/CS/SCLK/MOSI, UART1 TX/RX/CTS/RTS), all `FPGA_OUT`. 1 kHz by default,
every channel off until the host enables it, so an LED on each header pin
proves one channel.

## What you learn

Multi-channel outputs from one counter, a timing budget that still closes
with eight compare paths, and that in `FPGA_OUT` mode the RP2350's own SPI1 and
UART1 peripherals are disconnected from the header (the firmware sets GPIO
8-15 to input while this design is armed; the register bus still works because
it borrows the SPI1 inner nets only inside the IO_CONFIG_ENABLE window, and
`FPGA_OUT` pads keep driving through that window).

## Build & load

```sh
tools/fwfpga build pwm8
tools/fwfpga sim pwm8
tools/fwfpga install pwm8
tools/fwfpga load pwm8
```

The testbench checks the defaults, a 50 % channel at the 1 kHz default (15 616 / 31 232
clocks) and a 25 % channel at prescale 0.

UART RX (header pin 5, GPIO9) did not drive its header pin in testing;
do not rely on that channel.

## Verify

All eight header LEDs off after load. `fwfpga reg w 0x19 0xFF` (enable all)
changes nothing yet (duty 0). `fwfpga reg w 0x10 0x80` lights SPI MISO (GPIO12
LED) at 50 %, `0x14 0x20` dims UART TX (GPIO8) to 12.5 %, `0x17 0xFF` full on
RTS (GPIO11). An LED shows the duty cycle as brightness; a scope on the
header shows 1 kHz. `fwfpga reg w 0x18 0x00` raises
the PWM frequency to 122 kHz (prescale 0).

## Pins used

| signal | index | mode | register |
|---|---|---|---|
| SPI MISO (GPIO12) | 0 | `FPGA_OUT` | duty 0x10 |
| SPI CS (GPIO13) | 1 | `FPGA_OUT` | 0x11 |
| SPI SCLK (GPIO14) | 2 | `FPGA_OUT` | 0x12 |
| SPI MOSI (GPIO15) | 3 | `FPGA_OUT` | 0x13 |
| UART TX (GPIO8) | 4 | `FPGA_OUT` | 0x14 |
| UART RX (GPIO9) | 5 | `FPGA_OUT` | 0x15 |
| UART CTS (GPIO10) | 6 | `FPGA_OUT` | 0x16 |
| UART RTS (GPIO11) | 7 | `FPGA_OUT` | 0x17 |
| GPIO26 | 8 | `PASS_IN` | - |
| GPIO27 | 9 | `PASS_OUT` | - |

## Registers

| addr | R/W | contents |
|---|---|---|
| 0x10-0x17 | RW | duty of channel 0-7: high for `duty` of 256 phase steps (0 = off, 0x80 = 50 %, 0xFF = 99.6 %); default 0 |
| 0x18 | RW | prescale: phase step = (value + 1) clocks, period = 256 x (value + 1) clocks; default 121 = 1000.3 Hz |
| 0x19 | RW | enable mask, bit i = channel i; default 0 |
| 0x1A | R | current phase counter |
