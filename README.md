# wilifpga — FreeWili 2 FPGA Board Support Package

Build your own FPGA configurations for the FreeWili 2, by hand or with an AI
agent. Write a short Verilog module and a `design.toml`; the open-source
icestorm flow (yosys, nextpnr-ice40, icepack) turns it into a bitfile for the
board's **iCE40UP5K**, packed into a **`.fwfpga`** file that also carries the
design's IO directions. The firmware sets every pin direction from that file
before the design drives anything, so a design cannot fight the board over a
pin.

**Agents:** read [`AGENTS.md`](./AGENTS.md) first.

## Requirements

- A FreeWili 2 running firmware with FPGA BSP support (the `h\f` menu),
  coming in an upcoming FreeWili 2 firmware release, with power zone 6 on
  (`h\p\s 6 1`).
- Python 3.11+ and `pyserial`.
- The pinned oss-cad-suite (`tools/fwfpga toolchain install`, ~1 GB), or your
  own copy pointed to by `$OSS_CAD_SUITE`.

## Quick start

```sh
tools/fwfpga toolchain install
tools/fwfpga build hello_blink        # -> build/designs/hello_blink/hello_blink.fwfpga
tools/fwfpga sim hello_blink
tools/fwfpga install hello_blink      # upload to the board's SD card over USB
tools/fwfpga load hello_blink         # header GPIO26 blinks
tools/fwfpga restore                  # back to the stock gateware
```

Windows: `tools\fwfpga`. Tutorials start at
[`docs/learn/01-first-bitfile.md`](docs/learn/01-first-bitfile.md).

## Designs

| Design | What it shows |
|---|---|
| `template` | register 0x10 bit 0 drives GPIO26; the starting point for `fwfpga new-design` |
| `hello_blink` | heartbeat on GPIO26, blink rate in register 0x10 |
| `hello_regs` | eight user registers; GPIO26/27 follow bits of 0x10 |
| `pwm8` | eight PWM channels on the header |
| `freq_counter` | edge counters on three inputs with a 1 s gate |
| `logic_capture` | 8-channel logic sampler into the stream FIFO |
| `pio_link` | FPGA-clocked 8-bit parallel link into the RP2350 |
| `pio_stream` | RP2350-clocked, lossless continuous capture |
| `pio_sink` | RP2350 → FPGA link |

## Repo map

```
AGENTS.md        rules and workflow for agents
designs/         the designs above
fpga/            shell/ (fixed top level), lib/, constraints/fw2.pcf, sim/
tools/           fwfpga CLI and the container / profile / checker tools, tests/
docs/            contract, file format, toolchain, IO directions, data paths, drivers/, learn/
skills/          agent skills: new design, add a register peripheral, verify on the board
```

## Docs

- Design contract: [`docs/fpga-design-contract.md`](docs/fpga-design-contract.md)
- `design.toml` and the `.fwfpga` file: [`docs/fwfpga-format.md`](docs/fwfpga-format.md)
- Toolchain and CLI: [`docs/toolchain.md`](docs/toolchain.md)
- IO directions: [`docs/io-direction.md`](docs/io-direction.md)
- Moving data: [`docs/data-paths.md`](docs/data-paths.md)
- Shell registers and stream FIFO: [`docs/drivers/`](docs/drivers/)
- Tutorials: [`docs/learn/`](docs/learn/)

## Safety

- Header GPIO26 and GPIO27 go high for up to about 250 ms during every load.
  Do not connect anything to them that a stray high level would harm.
- Nothing here writes the FPGA's one-time-programmable memory; `fwfpga
  restore` or a power cycle always brings the stock gateware back.

## License

[FreeWili 2 Hardware License](LICENSE): free to use, modify and share, for
use with FreeWili 2 hardware only. Files that come from the FreeWili stock
gateware are listed in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
