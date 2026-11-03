# Toolchain and the `fwfpga` CLI

Everything here is the open-source icestorm flow from
[YosysHQ oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build):
yosys (synthesis), nextpnr-ice40 (place, route, timing), icepack (bitstream),
iverilog + vvp (simulation) and verilator (lint). No iCEcube2, no Lattice
licence, no NVCM. Python 3.11 or newer is required (`tomllib`); `pyserial` is
needed only for the device commands.

## Install

```bash
tools/fwfpga toolchain install      # Linux/macOS/Git Bash
tools\fwfpga toolchain install      # Windows (fwfpga.cmd)
tools/fwfpga toolchain check        # prints the version of every tool
```

The CLI pins one dated release, `OSS_CAD_SUITE_RELEASE = "2026-10-31"` in
`tools/fwfpga.py`, and installs it to
`~/.oss-cad-suite/<release>/oss-cad-suite/` (the archive's own top folder).
`install` downloads
`https://github.com/YosysHQ/oss-cad-suite-build/releases/download/<release>/oss-cad-suite-<os>-<arch>-<yyyymmdd>.tgz`,
prints its SHA-256 (pass `--sha256 <digest>` to enforce one), extracts it and
re-runs `check`. An existing install is left alone unless `--force`.

Lookup order at run time:

1. `OSS_CAD_SUITE` environment variable: the suite directory or its `bin/`.
   Use this to point at an existing install (an apio-managed toolchain works
   if you give it a directory with `bin/`).
2. The pinned install above (`OSS_CAD_SUITE_ROOT` overrides `~/.oss-cad-suite`).
3. `PATH`.

On Windows the suite's `bin/*.exe` files are launchers that need `lib/` on
`PATH`; the CLI prepends both for every tool it runs, so you do not have to
source `environment.bat`. The Perl `verilator` script does not run on a plain
Windows machine, so the CLI calls `verilator_bin.exe` there.

The suite is about 1 GB on disk; that is the price of a pinned, reproducible
flow that works identically on Windows and Linux.

## Commands

| Command | What it runs |
|---|---|
| `fwfpga new-design <name>` | copies `designs/template`, rewrites the token `template` to `<name>` (file contents and names), allocates the next free `design_id` |
| `fwfpga build <design> [--freq MHz]` | `check_design.py` -> `gen_design_id.py` -> yosys `read_verilog -Ifpga/shell -Ibuild/designs/<name> -I<lib dirs with .vh> <shell> <lib> <design>; synth_ice40 -top fw2_shell -json` -> `nextpnr-ice40 --up5k --package sg48 --pcf fpga/constraints/fw2.pcf --json --asc --freq <MHz> --report report.json` -> `icepack` -> `pack_fwfpga` -> `check_container`. Top is `main` for `kind = "stock"` (or `design.toml` `top`); the file list honours `sources`/`include_dirs` (see fwfpga-format.md). Output `build/designs/<name>/<name>.fwfpga` plus `report.json`, `yosys.log`, `nextpnr.log`. Prints utilisation and Fmax; exits 1 if any clock's achieved Fmax is below the requested frequency (contract rule 5) or if nextpnr constrained no clock |
| `fwfpga lint <design>` | `verilator --lint-only -Wall --top-module fw2_shell` over the same file list; an optional `fpga/lint.vlt` (verilator configuration file with explicit `lint_off` rules, e.g. for third-party modules) is passed when present |
| `fwfpga sim <design>` | `iverilog -g2012 -I fpga/sim -Ifpga/shell -Ibuild/designs/<name> -I<lib dirs with .vh>` over `designs/<name>/tb/*.v`, `fpga/sim/*.v` (bus-functional models, not `tb_*.v`), shell, lib and design, plus yosys's `share/yosys/ice40/cells_sim.v` for the `SB_*` primitives (`ICE40_CELLS_SIM` overrides the path); then `vvp -N`. Exit 1 on a non-zero vvp status or `$fatal`/`FATAL`/`ERROR` in the output. `fwfpga sim shell` runs `fpga/sim/tb_shell.v` against `fpga/sim/tb_design/` into `build/sim/` |
| `fwfpga inspect <file.fwfpga>` | header, direction summary and per-signal table; `--manifest` prints the JSON blob |
| `fwfpga install <design\|file>` | `check_container` (refuses anything that is not a valid container whose header matches `designs/<name>/design.toml`), then file put to `/fpga/<name>.fwfpga` |
| `fwfpga load <design\|file\|/path>` | `h\f\l "/fpga/<name>.fwfpga"`; prints `design_id version cdone load_ms` |
| `fwfpga restore` | `h\f\t` (Restore Stock; `d` is reserved by the menu system) |
| `fwfpga status` | `h\f\s`; payload `source armed cdone id version caps clock_hz profile name load_ms error`, printed with the profile decoded |
| `fwfpga reg r <addr> [count]` | `h\f\r <addr> <count>` (count defaults to 1) |
| `fwfpga reg w <addr> <bytes>` | `h\f\w <addr> <bytes>`; bytes as typed (`0x80`, `128`, `80AB`, `1 2 3`) |
| `fwfpga stream rx <n> [-o file]` | `h\f\x <n>`; hex payload decoded to a dump or a file; a path payload is reported for `h\x\u` retrieval |
| `fwfpga test [--no-sim]` | pytest over `tools/tests` and `tests/`; then `sim` for every design with a `tb/` when iverilog is available |

Global flags: `--print` runs nothing and prints every external command line
and every byte that would go to the device (the test suite relies on it);
`--port COMx` overrides device auto-detection; `-v` logs device traffic.

The exact yosys/nextpnr command lines are in `yosys_command()` and
`nextpnr_command()` in `tools/fwfpga.py`; keep them in step with
`fpga/README.md`, which is where the gateware side documents its working
flow.

## Talking to the board

MAIN enumerates as USB VID `0x093C` PID `0x205A` and is found with
`serial.tools.list_ports`. The protocol is the plain menu protocol at 115200
baud: send `0x03` (menu to root), then the wire path, arguments and `\n`;
replies are framed `[<path> <ts> <seq> <payload> <0|1>]` and event frames
start with `*`. File upload (`fwfpga install`) sends
`h\x\f <devpath> <size> <crc32>` with size and zlib CRC-32 in decimal, waits
for a frame whose body contains `Send File Now`, streams the raw bytes, and
waits for the completion frame (`success <N> bytes` or `Failed checksum`). If
the one-line form gets no handshake the CLI falls back to the stepwise form
(`h`, `x`, `f`, then the header line); `--stepwise` forces it. The transport
lives in the `Wire` class so it is tested against a scripted fake serial port;
record hardware results in the design's README.

## Where things land

```
build/designs/<name>/
  fw2_design_id.vh     generated from design.toml (ID block constants)
  <name>.json          yosys netlist
  <name>.asc  <name>.bin   nextpnr / icepack intermediates (git-ignored)
  report.json          nextpnr utilisation + Fmax
  yosys.log  nextpnr.log
  <name>.fwfpga        the only deliverable (see fwfpga-format.md)
```

## Host-side checks without the toolchain

`py -3 -m pytest tools/tests tests` needs neither the toolchain nor a board:
profile encode/decode, `design.toml` validation, ID block bytes, container
pack/unpack with every single-byte header corruption, the generated C header
compiled with host gcc against Python-packed bytes (skipped when no compiler is
found), `check_design` rules, CLI dry runs and the transport against a fake
serial port.
