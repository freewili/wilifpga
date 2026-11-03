# `fw2_shell` driver notes: register bus, directions, arm gate

How the shell in `fpga/shell/` behaves on its register bus and pins.
`fpga/sim/tb_shell.v` (`fwfpga sim shell`) checks all of it.

## 1. SPI register bus: mode, timing, gating

* **Mode 0, 8-bit frames, MSB first.** The slave samples MOSI on the SCK
  rising edge and changes MISO on the falling edge; CS is a GPIO on the
  RP2350 held low for the whole transaction. The firmware configures SPI1 as
  `CPOL=0, CPHA=0`, 8 bits, 3.25 MHz at the stock fabric clock.
* **Command byte:** bit 7 = 1 read, 0 write; bits [6:0] = 7-bit register address.
  Then any number of data bytes until CS rises.
* **Gating by IO_CONFIG_ENABLE.** The slave core is held in reset while the
  pin is low (`spi_slave.v`: `if (resetn == 1'b0 || en == 1'b0)` clears the
  shift register, bit counter and `first_byte`; the shell ties `en` to
  IO_CONFIG_ENABLE), and register writes are additionally gated with
  `io_config_enable == 1'b1 && wr == 1'b1`. While the pin is low the four SPI1
  inner nets are plain passthrough to the header; while high the shell drives
  `SPI_MISO_Rp` from the bus, releases the other three SPI `_Rp` pads and
  all four SPI `_Out` pads that pass through, and restores them when the pin
  falls (`fw2_io_buffer.v`, `cfg` term).
* **Sampling scheme and SCK ceiling.** Two-stage synchronisers on SCK and CS,
  edge detection one clock later, byte strobe one clock after that, address
  update one clock after that. A new read byte must be ready before the falling
  edge following the byte's 8th rising edge, which leaves about `SCK_half -
  3 fabric clocks` of margin. At a 31.25 MHz fabric clock `tb_shell` passes at
  3.25 and 5.0 MHz SCK and fails at 6.25 MHz (second byte of a burst returns the
  first byte's value). **Rule: SCK <= 5 MHz at 31.25 MHz**, i.e. SCK at most
  about FPGA_CLK / 6.25; the firmware's 3.25 MHz is safe, and it scales SCK
  down for designs built for a slower clock code (section 6).

## 2. Burst semantics: auto-increment, with a pre-decrement on writes

The slave (`fpga/shell/fw2_spi_slave.v`) takes the address from the command
byte. Reads use it directly; writes pre-decrement it, because `data_valid` and
the auto-increment are registered in the same clock, so a write slave sees the
address already incremented when `data_valid` is high.

What this means on the wire, for a command with address `A`:

| transaction | after the command byte `addr` = | data byte 1 | data byte 2 | data byte k |
|---|---|---|---|---|
| write (cmd `A`) | `A-1` (pre-decrement) | lands at `A` (`data_valid` is asserted in the same clock that `addr` becomes `A`) | `A+1` | `A+k-1` |
| read (cmd `0x80|A`) | `A` | returns `reg[A]` (`tx_data` is loaded at the falling edge after the command's 8th rising edge, when `addr == A`) | `reg[A+1]` | `reg[A+k-1]` |

So **the bus is auto-increment for both directions and, from the host's point
of view, data byte k of either transaction addresses `A + k - 1`.** The
pre-decrement is internal. A read with command `0x82` followed by two clocked
bytes returns `reg[0x02]`, `reg[0x03]`, and a 16-byte read from `0x70` returns
the ID block in order.

### What the shell's slave adds over the stock one

* `hold` input: when high, the address does not increment after a data byte.
  The shell asserts it for `addr == 0x60` or `0x61`, giving **hold-address
  bursts on the two FIFO data registers**. Writes still take their first
  increment (undoing the pre-decrement) so a write to `0x60` lands at `0x60`
  and stays there; reads hold from data byte 1. Every other address keeps the
  auto-increment. Consequence: a write burst that *starts* at `0x5F` will
  stick at `0x60` from its second byte (documented, harmless).
* `rd_done` / `rd_done_addr`: a one-clock strobe after each data byte of a
  read, carrying the address of the byte that was just shifted out. The shell
  uses it to pop the RX FIFO, to clear the sticky status flags when `0x62` has
  been read, and to give `user_core` its `reg_rd` strobe. The stock slave has
  no read strobe.
* Everything else (command parsing, `wr`, `data_valid` timing) is unchanged, so
  the firmware's existing register sequences behave the same.

## 3. Direction readback (0x02/0x03) and the DIR balls

The shell keeps the stock gateware's two direction bytes as **read-only**
values derived from the profile:

* **Bit = 1 means the FPGA drives the `_Out` pad (header side)**: the RP2350
  output reaches the header (`PASS_OUT`), or the design drives the header
  (`FPGA_OUT`). **Bit = 0 for every other mode.**
* **Bit map:**

  | reg 0x02 bit | 7 | 6 | 5 | 4 | 3 | 2 | 1 | 0 |
  |---|---|---|---|---|---|---|---|---|
  | signal | UART CTS (GPIO10) | SPI SCK (14) | SPI CS (13) | SPI MISO (12) | SPI MOSI (15) | UART TX (8) | UART RX (9) | UART RTS (11) |

  | reg 0x03 bit | 1 | 0 |
  |---|---|---|
  | signal | GPIO26 | GPIO27 |

  Example: `hello_regs` (GPIO26 and GPIO27 `FPGA_OUT`) reads back `6C 03`.
* **Shifter DIR ball polarity (GPIO26/27, FPGA balls 35/40):** DIR = 1
  whenever the FPGA drives the header pad = "toward header"; DIR = 0 =
  "toward board" (the header drives the FPGA). The disarmed shell holds both
  at 0.
* **During a load the FPGA does not drive the DIR balls.** While it is in
  reset or configuring, header GPIO27 goes high for about 200-250 ms and
  header GPIO26 for about 30-100 ms, on every load. Never
  connect anything to GPIO26/27 that a high level during a load would harm.
* **No run-time direction changes:** register 0x04 reads 0 and ignores
  writes (contract rule 4).

## 4. The shell's register map (0x00-0x0F) and arm gate

| addr | R/W | contents |
|---|---|---|
| 0x01 | W | bit 0 = 1: one-clock synchronous reset of the shell and `user_core` (`fw2_rst_ctrl_reg`, self-clearing). Clears `IO_ARM`. Reads 0x00. |
| 0x02 | R | direction byte 0, derived from the profile (section 3). **Writes are ignored** (rule 4); the firmware does not apply its direction menus while a design is armed. |
| 0x03 | R | direction byte 1: `{6'b0, GPIO26, GPIO27}` by the same rule. |
| 0x04 | R | 0x00. |
| 0x0D | R | `CONTENTION_GPIO`: `{6'b0, GPIO27, GPIO26}` (bit 0 = GPIO26 = signal 8, bit 1 = GPIO27 = signal 9: bundle order, **not** the 0x03 order). Sticky pad-readback contention flags, see below. Writes ignored. |
| 0x0E | R | `CONTENTION`: bit i = header signal i in bundle order (0 SPI_MISO, 1 SPI_CS, 2 SPI_SCLK, 3 SPI_MOSI, 4 UART_TX, 5 UART_RX, 6 UART_CTS, 7 UART_RTS). Sticky pad-readback contention flags, see below. Writes ignored. |
| 0x0F | R/W | bit 0 `IO_ARM`, bit 1 `RESET_SINCE_ARM`. Resets to 0x00. Any write updates bit 0 and clears bit 1. A reset (0x01 or power-up) while armed clears bit 0 and sets bit 1; a reset while disarmed leaves bit 1 clear. |
| other | R | 0x00. |

Pad-readback contention flags (0x0D/0x0E, `fw2_shell.v` `g_cont`), enforced
in `tb_shell` section 7:

* **What sets a bit.** Only a signal whose profile mode is `FPGA_OUT` has a
  detector. While `IO_ARM = 1` and the pad is driven (`hdr_oe` from the user
  core is 1), the `_Out` pad's `SB_IO` input (`hdr_i`, the real pin level) is
  compared every fabric clock with the value the shell drives (`hdr_out`). When
  they differ for `FW2_CONT_FILTER` consecutive clocks (default 32, about 1 µs
  at 31.25 MHz) the signal's bit is set. A pad transition settles in fewer
  clocks and never sets a bit, and separate short disagreements do not
  accumulate (the run counter restarts at every agreeing clock). A set bit
  means something on the header side, the level shifter or a device on the
  header, is overpowering the FPGA pad: the state rule 4 forbids but cannot
  prevent.
* **What never sets a bit.** Signals in `PASS_OUT`, `PASS_IN`, `FPGA_IN`,
  `LINK_RP2F`, `LINK_F2RP` or `OFF` (their bits are constant 0), any signal
  while `IO_ARM = 0`, and an `FPGA_OUT` signal whose `hdr_oe` is 0 (the pad is
  an input then, so there is nothing to compare). The bus cannot set a bit:
  writes to 0x0D/0x0E are ignored.
* **What clears.** Sticky until read: the shell's read strobe (`rd_done`) for
  0x0E clears bits 7..0, the strobe for 0x0D clears bits 9..8, each only its
  own byte (a 2-byte burst read from 0x0D returns and clears both). A hit in
  the same clock as the clear wins, so a fight still in progress is reported
  again by the next read. Both bytes also clear on register 0x01 reset and on
  disarm (`IO_ARM` 1 -> 0), and read 0 while disarmed.
* **GPIO27 is slow to rise.** Its header-side pad is open-drain with a pull-up,
  so a rising edge takes about 6 clocks (0.19 µs) to read 1 in the fabric. The default filter has plenty of margin; a filter of
  4 clocks would flag every GPIO27 rising edge.
* **Cost.** A small run counter plus one flag per `FPGA_OUT` signal; the ID
  block, capabilities and profile bytes are unchanged.

Arm gate behaviour (`fw2_io_buffer.v`, enforced in `tb_shell`):

* `IO_ARM = 0` (boot state): every `_Rp` and `_Out` pad output enable is 0,
  `GPIO_26_Dir = GPIO_27_Dir = 0` (toward board). The one exception is
  `SPI_MISO_Rp`, driven by the register bus **only while IO_CONFIG_ENABLE is
  high**, so the firmware can read the ID block.
* `IO_ARM = 1`: pads drive exactly as the profile says (`PASS_OUT`: `_Out`
  follows `_Rp`; `PASS_IN`: `_Rp` follows `_Out`; `FPGA_OUT`: `_Out` =
  `hdr_out & hdr_oe`; `LINK_F2RP`: `_Rp` = `rp_out`; everything else Z), DIR
  balls = 1 for `PASS_OUT`/`FPGA_OUT` on GPIO26/27.
* Inside the IO_CONFIG_ENABLE window the four SPI inner nets belong to the bus
  regardless of arm (MISO_Rp driven, CS/SCK/MOSI `_Rp` released) and the
  `PASS_OUT` SPI `_Out` pads release (stock behaviour). `FPGA_OUT` pads keep driving through the window (they do not depend on the
  inner net), so a design driving the SPI header pins does not glitch on every
  register access.
* `IO_ARM = 0` or a reset returns everything to Z without disturbing the
  register bus.
* `I2C_SDA` is open-drain and not driven unless the design has
  `I2C_SLAVE`; the other pads the shell does not use are held as inputs or
  idle (section 4a).

## 4a. Pads

Every bidirectional pad is an explicit `SB_IO` (`fpga/shell/fw2_pad.v`;
`fw2_pad_od.v` is the open-drain version for SDA), because yosys turns
`assign PAD = 1'bz;` into a pad that drives 0. Fabric logic reads a pad only
through its SB_IO input (`rp_i` / `hdr_i`). `fpga/sim/check_netlist_pads.py`
checks the netlist of every build.

## 5. User register window and strobes (`fw2_user_core.vh`)

* `reg_addr` is the **absolute** 7-bit bus address; the shell only asserts
  `reg_wr`/`reg_rd` for 0x10-0x5F and only consumes `reg_rdata` there.
* `reg_wr`: one clock, `reg_wdata` is the byte written to `reg_addr`.
* `reg_rd`: one clock after a data byte of a read has been shifted out; during
  that clock `reg_addr` holds the address of that byte (the shell muxes
  `rd_done_addr` in), the next clock it is the following address again.
  `reg_rdata` for the following byte is sampled by the SPI slave no earlier
  than two fabric clocks after `reg_rd` falls at 5 MHz SCK, so a combinational
  `reg_rdata` from registered state is sufficient.

## 6. Clock codes (ID block byte 0x7A)

`clock_hz` in `design.toml` selects the code; the firmware sets FPGA_CLK
(RP2350 GPIO24 into FPGA ball 37) while the FPGA is held in reset, before the
bitstream goes in.

| code | `clock_hz` | how the RP2350 makes it (150 MHz system clock) | notes |
|---|---|---|---|
| 0 | 31 250 000 | `clk_sys` / (4 + 205/256) = 31.245 MHz | fractional: periods alternate between 4 and 5 system clocks, so the shortest cycle is 26.7 ns (a 37.5 MHz cycle). Build designs to meet 37.5 MHz (`fwfpga build <design> --freq 37.5`). |
| 1 | 12 500 000 | `clk_sys` / 12 | clean; register-bus SCK is scaled down |
| 2 | 25 000 000 | `clk_sys` / 6 | clean |
| 3 | 48 000 000 | USB clock / 1 | clean; only small designs meet 48 MHz with the shell |

`fwfpga status` reports the clock actually generated (31244914 Hz for
code 0).
