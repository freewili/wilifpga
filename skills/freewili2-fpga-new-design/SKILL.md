---
name: freewili2:fpga-new-design
description: Use when creating a new iCE40 design for the FreeWili 2 FPGA BSP (wilifpga) — scaffold designs/<name> from the template, fill design.toml and user_core.v, lint, simulate, build the .fwfpga container, install, load, check status and record the result.
---

# freewili2:fpga-new-design

Take a design from "I want the FPGA to do X" to a `.fwfpga` running on the
board with a recorded result, without reading anything but this skill and
`AGENTS.md`. Every command runs from the repo root; `tools/fwfpga` is the
launcher (`tools\fwfpga` on Windows).

## Procedure

1. **Decide the IO profile first.** For each of the ten header signals
   (spi_miso 12, spi_cs 13, spi_sclk 14, spi_mosi 15, uart_tx 8, uart_rx 9,
   uart_cts 10, uart_rts 11, gpio26, gpio27) pick one mode: `PASS_OUT` /
   `PASS_IN` (stock passthrough), `FPGA_OUT` / `FPGA_IN` (the fabric owns the
   header pin), `LINK_RP2F` / `LINK_F2RP` (fast inner-net link to the RP2350),
   `OFF`. Ask which net the user means if "GPIO" is ambiguous (`AGENTS.md`).
   Only GPIO26/27 have carried `FPGA_OUT` on hardware so far.

2. **Scaffold.**

   ```sh
   tools/fwfpga new-design <name>
   ```

   Copies `designs/template/` (one register, GPIO26 `FPGA_OUT`), rewrites the
   token `template` in file contents and names, allocates the next free
   `design_id`. Fails if the folder exists.

3. **Edit `designs/<name>/design.toml`.** `description` (<= 127 ASCII, what
   the device panel shows), `version = "001"` (three digits, hand-bumped on
   every behavioural change), `clock_hz = 31250000` (the only code the
   firmware accepts in v1), `capabilities` (`IO_BUFFER`; add `STREAM` for the
   FIFO window), the `[io_profile]` table from step 1, optional `[registers]`
   notes (copied into the container manifest). Unknown keys are errors.

4. **Write `designs/<name>/user_core.v`.** Keep the port list exactly as in
   `fpga/shell/fw2_user_core.vh`. Rules: one clock (`clk`), synchronous
   `rst_n`; `reg_addr` is the absolute bus address (decode `7'h10`, not 0);
   `reg_rdata` combinational; `hdr_out`/`hdr_oe` bits only for slots the
   profile marks `FPGA_OUT` (indices `FW2_SIG_*` in `fpga/shell/fw2_profile.vh`);
   `rp_out` only for `LINK_F2RP`; tie unused outputs to 0 and fold unused
   inputs into the `unused` wire; never a pad name from `fw2.pcf`.
   Register-window pattern: `freewili2:fpga-add-register-peripheral`.

5. **Unit test.** Edit `designs/<name>/tb/tb_user_core.v` (drive
   `reg_addr`/`reg_wdata`/`reg_wr` directly; `$fatal` on mismatch).

   ```sh
   tools/fwfpga lint <name>      # verilator -Wall, warnings fatal
   tools/fwfpga sim <name>       # iverilog + vvp; exit 1 on $fatal/ERROR
   tools/fwfpga sim shell        # optional: the shell testbench still passes
   ```

6. **Build.**

   ```sh
   tools/fwfpga build <name>
   ```

   Runs `check_design` -> `gen_design_id` -> yosys -> nextpnr (`--freq`
   31.25) -> icepack -> `pack_fwfpga` -> `check_container`. Note the LC count
   and Fmax it prints (template 179 LCs / 52.2 MHz, hello_blink 232 / 57.2,
   hello_regs 387 / 43.6). **Exit 1 on an Fmax below the clock is a timing
   failure to fix in the design**, never with `--timing-allow-fail`.
   Output: `build/designs/<name>/<name>.fwfpga`. `tools/fwfpga inspect` on it
   shows the header and the direction summary.

7. **Write `designs/<name>/README.md`** with the sections every design has:
   What you learn / Build / Simulate / Install & load / Verify / Pins used /
   Registers. Say "unverified on hardware" until step 9 is done.

8. **Install and load** (FPGA powered with `h\p\s 6 1`; MAIN is USB VID 093C PID 205A,
   `--port <port>` to override; `--print` to dry-run every byte first).

   ```sh
   tools/fwfpga install <name>              # check_container, then h\x\f to /fpga/<name>.fwfpga
   tools/fwfpga load <name>                 # expect: design_id N  version N  cdone 1  load_ms ~273
   tools/fwfpga status                      # expect: source file, armed 1, cdone 1, your id and profile
   tools/fwfpga reg r 0x70 16               # ID block: 46 57 32 46 01 <id LE> <ver LE> <caps> 00 <profile LE> <xor>
   ```

   A single token instead of the four numbers is the failed check:
   `header:no-file`, `header:not-a-fwfpga`, `header:header-crc`,
   `bitstream-crc`, `idblock:<field>`, `cdone`, `arm`,
   `clock-code-unsupported`. Stock is restored (header failures change
   nothing). `docs/learn/01-first-bitfile.md` has the table.

9. **Verify and record** — follow `freewili2:fpga-bringup-verify`: stimulate
   with `tools/fwfpga reg w`, observe the header pins (LED, meter or logic
   analyzer), `tools/fwfpga restore`, and record the commands, replies and
   observations in the README's Verify section.
   No board: say "unverified" in the README and the report.

10. **Hygiene.** `py -3 -m pytest tests tools/tests -q`
    (`design.toml` rules, container tests). Conventional Commit:
    `feat(designs): <name> — <one line>`.

## Reference

- `AGENTS.md` — workflow, commands, rules, IO profile, register map, board facts.
- `docs/fpga-design-contract.md` — the rules with code excerpts.
- `docs/fwfpga-format.md` — `design.toml` keys, profile encoding, ID block,
  container header.
- `docs/drivers/shell.md` — bus timing, strobes, direction bits, arm gate.
- `designs/template`, `designs/hello_blink`, `designs/hello_regs` — the three
  smallest examples.
- `docs/learn/01-first-bitfile.md`, `02-registers.md`.
