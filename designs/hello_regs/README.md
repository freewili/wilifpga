# hello_regs

Eight read/write registers at 0x10-0x17 plus three read-only status bytes;
header pins **GPIO26 and GPIO27** mirror bits 0 and 1 of register 0x10.

## What you learn

The user register window: absolute addresses, the one-clock `reg_wr` strobe,
burst (auto-increment) reads and writes from the host, the `reg_rd` strobe for
read side effects (0x19 counts reads of 0x17), and two `FPGA_OUT` pins at once
(both DIR balls toward the header).

## Build & load

```sh
tools/fwfpga build hello_regs
tools/fwfpga sim hello_regs
tools/fwfpga install hello_regs
tools/fwfpga load hello_regs
```

## Verify

Write eight bytes in one burst (`fwfpga reg w 0x10 ...` per byte today), read
them back; `fwfpga reg r 0x18` counts the writes, `0x1A` returns their XOR.
`fwfpga reg w 0x10 0x01` drives header GPIO26 high, `0x02` GPIO27, `0x03`
both (check with an LED, meter or logic analyzer on the pins).

## Pins used

| signal | mode |
|---|---|
| GPIO26 | `FPGA_OUT` = register 0x10 bit 0 |
| GPIO27 | `FPGA_OUT` = register 0x10 bit 1 |
| SPI MISO, UART RX, UART CTS | `PASS_IN` |
| SPI CS/SCLK/MOSI, UART TX/RTS | `PASS_OUT` |

## Registers

| addr | R/W | contents |
|---|---|---|
| 0x10-0x17 | RW | eight scratch registers; 0x10 bits 1:0 drive GPIO27:GPIO26 |
| 0x18 | R | number of writes into 0x10-0x17 (mod 256) |
| 0x19 | R | number of host reads of 0x17 (mod 256), demonstrates `reg_rd` |
| 0x1A | R | XOR of the eight registers |
