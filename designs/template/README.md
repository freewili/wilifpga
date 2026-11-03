# template

The smallest useful FW2 design: one read/write register (0x10) whose bit 0
drives header pin **GPIO26**. `fwfpga new-design <name>` copies this folder.

## What you learn

The shape of every design: `design.toml` (identity + IO profile),
`user_core.v` (your logic behind the fixed port list), `tb/tb_user_core.v`
(unit test of your core alone). Nothing here names a pad; the shell owns them.

## Build & load

```sh
tools/fwfpga build template
tools/fwfpga sim template
tools/fwfpga install template
tools/fwfpga load template
```

`tools/fwfpga sim shell` runs the shell-level checks (ID block, directions,
arm gate).

## Verify

`fwfpga status` shows design id 1, version 001. `fwfpga reg w 0x10 0x01` turns
GPIO26 high at the header (an LED or meter on the pin),
`fwfpga reg w 0x10 0x00` turns it off; `fwfpga reg r 0x10` reads back the
value. Reading `0x02`/`0x03` returns `0x6C 0x02` (profile below in stock format).

## Pins used

| signal | mode | why |
|---|---|---|
| GPIO26 | `FPGA_OUT` | the one output |
| SPI MISO, UART RX, UART CTS | `PASS_IN` | stock passthrough, header drives RP2350 |
| SPI CS/SCLK/MOSI, UART TX/RTS, GPIO27 | `PASS_OUT` | stock passthrough, RP2350 drives header |

## Registers

| addr | R/W | contents |
|---|---|---|
| 0x10 | RW | bit 0 = GPIO26 level; other bits stored, unused |
| 0x11-0x5F | R | 0x00 |

Shell registers (0x01 reset, 0x02/0x03 directions, 0x0F IO_ARM, 0x70-0x7F ID
block) are documented in `docs/drivers/shell.md`.
