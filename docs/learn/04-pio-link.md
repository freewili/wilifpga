# Learn 04 — The PIO link: megabytes per second

**What you learn.** How a design moves data at MB/s over the direct
RP2350 ↔ FPGA wires, and the two ways to clock the link.

**You need.** Tutorials 01-03.

## 1. The wires

Each header signal also has an inner net, a direct wire between the RP2350
pin and the FPGA. The `LINK_*` modes use those, and the header pins stay out
of it:

| Signal | RP2350 GPIO | Role |
|---|---|---|
| UART TX/RX/CTS/RTS, SPI MISO/CS/SCLK/MOSI | 8-15 | 8-bit data: bit k on GPIO 8+k (bits 0-3 on the UART signals, 4-7 on the SPI signals) |
| GPIO26 | 26 | link clock |

`LINK_F2RP` = the FPGA drives the wire to the RP2350; `LINK_RP2F` = the RP2350
drives it to the FPGA. In your core they are `rp_in[]` / `rp_out[]`, indexed
by `FW2_SIG_*`.

## 2. Two ways to own the clock

**The FPGA drives the clock** (`designs/pio_link`, GPIO26 `LINK_F2RP`). The
fastest path, about 15.6 MB/s, but the RP2350 cannot slow the FPGA down, so a
capture is a series of 32 KB bursts.

```sh
tools/fwfpga stream pio 65536 -o link.bin --check
```

**The RP2350 drives the clock** (`designs/pio_stream`, `designs/pio_sink`,
GPIO26 `LINK_RP2F`). The RP2350 pauses the clock when its buffer is full, so
nothing is lost and a capture can be any length; about 5.2 MB/s into the
RP2350 and 5.36 MB/s out to the FPGA.

```sh
tools/fwfpga stream pio 8388608 --continuous --div 1 --check -o stream.bin   # FPGA -> RP2350
tools/fwfpga stream tx 8388608 --div 1 --check                              # RP2350 -> FPGA
```

## 3. Rules for an RP2350-clocked design

- Synchronise GPIO26 into `clk` and act on one edge: a capture design changes
  its data on the **falling** edge; a receive design takes data on the
  **rising** edge.
- Do not expect register traffic during a stream: the register bus shares
  four of the data wires (SPI).

## What can go wrong

- **Pattern errors with the FPGA-clocked link:** check that data changes on
  one clock edge and is stable on the other.
- **Stream refused or nothing captured:** the profile does not mark GPIO26
  and the data pins with the `LINK_*` direction the command needs.
- **Header devices:** `LINK_*` leaves the header pins undriven by the FPGA;
  use `OFF` for pins you do not need.
