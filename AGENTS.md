# AGENTS.md — wilifpga (FreeWili 2 FPGA BSP)

This repo lets you, a coding agent, turn a design into a loadable FPGA file
for the **iCE40UP5K** on the **FreeWili 2**: write `user_core.v` and
`design.toml`, build with the open-source icestorm flow, load the result on
the board and check it. Read this file to the end before changing anything.

## The workflow

```sh
tools/fwfpga new-design <name>     # copy designs/template, allocate a design_id
# edit designs/<name>/design.toml and designs/<name>/user_core.v
tools/fwfpga lint <name>           # verilator, warnings are fatal
tools/fwfpga sim <name>            # designs/<name>/tb/*.v
tools/fwfpga build <name>          # -> build/designs/<name>/<name>.fwfpga; fails if timing is not met
tools/fwfpga install <name>        # upload to the board's SD card
tools/fwfpga load <name>           # design_id N version N cdone 1 load_ms ~273
tools/fwfpga status                # armed 1, your id and IO profile
tools/fwfpga reg w 0x10 0x01       # poke your registers, watch the pins
tools/fwfpga restore               # back to the stock gateware
```

Windows: `tools\fwfpga`. The step-by-step version is
`skills/freewili2-fpga-new-design/SKILL.md`; adding registers is
`skills/freewili2-fpga-add-register-peripheral/SKILL.md`; checking a design on
the board is `skills/freewili2-fpga-bringup-verify/SKILL.md`.

## Commands

| Command | What it does |
|---|---|
| `fwfpga toolchain install` / `check` | download the pinned oss-cad-suite (~1 GB) / print the tool versions found (`$OSS_CAD_SUITE` overrides) |
| `fwfpga new-design <name>` | new design from `designs/template` |
| `fwfpga lint` / `sim` / `build <name>` | lint, simulate, build + pack + check; `sim shell` runs the shell testbench |
| `fwfpga inspect <file.fwfpga>` | print the container header and IO table |
| `fwfpga install` / `load <name>` | upload, then load and arm |
| `fwfpga status` / `restore` | what is loaded / reload the stock gateware |
| `fwfpga reg r <addr> [n]` / `reg w <addr> <bytes>` | register bus, 1..64 bytes |
| `fwfpga stream rx` / `stream pio` / `stream tx` | move data out of or into a design (`docs/data-paths.md`) |
| `fwfpga test` | host tests and every design's testbench |

`--print` shows every command and every byte it would send without running
anything; `--port` picks the serial port.

## Rules a design must follow

The full contract with the reasons is `docs/fpga-design-contract.md`.

1. **Top is `fw2_shell`; you write only `user_core`** with the fixed port list
   in `fpga/shell/fw2_user_core.vh`. No pad names in a design file.
2. **Every design has a `design.toml`**: name, description, version, unique
   `design_id`, `clock_hz`, a mode for all ten header signals, capabilities
   (`docs/fwfpga-format.md`). Bump `version` on every behaviour change.
3. **Only `.fwfpga` files load.** They carry the IO directions; a bare
   bitstream is refused by the CLI and the firmware. Never write a `.bin`
   loader.
4. **Directions come only from `[io_profile]`.** No register can change one;
   the shell ignores `hdr_oe` outside `FPGA_OUT` and drives nothing the
   profile does not allow.
5. **Timing must be met at `clock_hz`** and lint must be clean. Never pass
   `--timing-allow-fail` or `--ignore-loops`.
6. **Never write the FPGA's one-time-programmable memory (NVCM).**
7. **The shell starts disarmed**: every pin is an input until the firmware has
   checked the design and set `IO_ARM` (register 0x0F). Do not rely on
   outputs before that.

## IO profile

Each of the ten header signals has an **inner net** (RP2350 pin ↔ FPGA) and
an **outer net** (FPGA ↔ level shifter ↔ header pin). Pick one mode per
signal in `design.toml [io_profile]`:

| Mode | Header pin | Use |
|---|---|---|
| `FPGA_OUT` | FPGA drives it | outputs from your logic |
| `FPGA_IN` | drives the FPGA | inputs to your logic |
| `LINK_RP2F` | not used | fast link, RP2350 → FPGA, on the inner net |
| `LINK_F2RP` | not used | fast link, FPGA → RP2350, on the inner net |
| `PASS_OUT` | RP2350 drives it through the FPGA | stock behaviour |
| `PASS_IN` | drives the RP2350 through the FPGA | stock behaviour |
| `OFF` | not used | unused signals |

Signals: `spi_miso` (GPIO12), `spi_cs` (13), `spi_sclk` (14), `spi_mosi` (15),
`uart_tx` (8), `uart_rx` (9), `uart_cts` (10), `uart_rts` (11), `gpio26`,
`gpio27`.

"Drive GPIO26 from the FPGA" can mean the header pin (`FPGA_OUT`) or the
RP2350 pin (`LINK_F2RP`). If a request does not say which, ask.

## Register map

| Range | Owner | Contents |
|---|---|---|
| 0x00-0x0F | shell | 0x01 reset (also disarms); 0x02-0x03 direction readback; 0x0F `IO_ARM` |
| 0x10-0x5F | **your `user_core`** | 80 user registers |
| 0x60-0x6F | shell, `STREAM` capability | stream FIFO (`docs/drivers/stream_fifo.md`) |
| 0x70-0x7F | shell | ID block, generated from `design.toml` |

Bus details: `docs/drivers/shell.md`.

## Board facts that affect a design

- **Power zone 6 must be on** (`h\p\s 6 1` on the board's menu) or the FPGA
  and the header are dead while every command still reports OK. Check it
  first when nothing happens.
- **Header GPIO26 and GPIO27 go high for up to about 250 ms during every
  load.** Do not connect anything to them that a stray high level would harm.
- **I2C SDA/SCL only pass by the FPGA.** Leave them alone unless the design
  has the `I2C_SLAVE` capability.
- **Clock**: `clock_hz` picks 31.25, 12.5, 25 or 48 MHz. 31.25 MHz has
  cycle-to-cycle jitter (its shortest cycle is a 37.5 MHz one): for
  designs close to their timing limit, build with `--freq 37.5`.
- **Register values are lost** when zone 6 is switched off; the design is
  reloaded with its registers at reset values.

## Adding a library module

New code goes in `fpga/lib/fw2_<name>/` with a `README.md` (what it does,
ports, registers). Test it in a design `tb/` or `fpga/sim/tb_shell.v`.

## Report honestly

"It builds" and "the testbench passes" are not a hardware result. When you
load a design, quote what the board replied. If no board is attached, say the
design is unverified on hardware.
