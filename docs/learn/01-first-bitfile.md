# Learn 01 — Your first bitfile: `hello_blink`

**What you learn.** How a design becomes a `.fwfpga` file, how to load it,
what `FPGA_OUT` means, and how to see the result on a header pin.

**You need.** Python 3.11+ with `pyserial`; a FreeWili 2 with FPGA BSP
firmware, connected over USB, with power zone 6 on (`h\p\s 6 1`); an LED,
meter or logic analyzer on header GPIO26.

## 1. Toolchain

```sh
tools/fwfpga toolchain check
tools/fwfpga toolchain install        # if tools are missing: pinned oss-cad-suite, ~1 GB
```

Or set `OSS_CAD_SUITE` to a suite you already have.

## 2. Read the design

`designs/hello_blink/` has what every design has:

- `design.toml`: name, `design_id = 2`, version, and the IO profile:
  `gpio26 = "FPGA_OUT"`, the other signals left as stock passthrough.
- `user_core.v`: a clock divider, a rate register at 0x10, a level readback at
  0x11, and `hdr_out` / `hdr_oe` set for GPIO26 only.
- `tb/tb_user_core.v`: a unit test of the core.
- `README.md`: pins, registers and how to try it.

`FPGA_OUT` on GPIO26 means the FPGA drives header pin GPIO26. You only write
that one word; the shell and the firmware set the level shifter and the
RP2350 pin to match.

## 3. Lint, simulate, build

```sh
tools/fwfpga lint hello_blink
tools/fwfpga sim hello_blink
tools/fwfpga build hello_blink
tools/fwfpga inspect build/designs/hello_blink/hello_blink.fwfpga
```

`build` prints the logic used and the Fmax, and fails if Fmax is below the
design's clock. `inspect` shows the header: id 2, version 1, profile summary
`drives: GPIO26`.

## 4. Install and load

```sh
tools/fwfpga install hello_blink      # checks the file, uploads it to /fpga/ on the SD card
tools/fwfpga load hello_blink         # design_id 2  version 1  cdone 1  load_ms ~272
tools/fwfpga status                   # source file, armed 1, name hello_blink
tools/fwfpga reg r 0x70 16            # ID block: 46 57 32 46 01 02 00 01 ...
```

## 5. See it

Header GPIO26 toggles at about 1.9 Hz; no other header pin changes.

```sh
tools/fwfpga reg w 0x10 0x00      # faster, ~15 Hz
tools/fwfpga reg w 0x10 0x3F      # slower, ~0.23 Hz
tools/fwfpga reg r 0x11           # bit 0 = current level
tools/fwfpga restore              # back to the stock gateware
```

## What can go wrong

A refused or failed load replies with one token:

| Token | Meaning |
|---|---|
| `header:no-file` | the file is not on the SD card |
| `header:not-a-fwfpga` | not a `.fwfpga` (a bare `.bin`?); nothing was touched |
| `header:header-crc` | damaged header; the running design is untouched |
| `bitstream-crc` | damaged bitstream; stock gateware reloaded |
| `idblock:<field>` | the fabric's ID block does not match the header; stock reloaded |
| `cdone` / `arm` | the FPGA did not configure / did not arm; stock reloaded |

- **Header dark, every command OK:** zone 6 is off.
- **GPIO26/27 pulse high during every load:** that is the board, not your
  design (`docs/io-direction.md`).

Next: `02-registers.md`.
