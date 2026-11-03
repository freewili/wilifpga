---
name: freewili2:fpga-bringup-verify
description: Use when checking a FreeWili 2 FPGA design on the real board (wilifpga) — the hardware checklist (FPGA power, load reply, CDONE, ID block, profile, header pins, passthrough, restore) and how to record the result as evidence.
---

# freewili2:fpga-bringup-verify

"It builds" is not evidence. Repeat this sequence for every design and write
down what the device actually replied. If no board is attached, stop and
report the work as **unverified**.

## Procedure

1. **Preconditions.** A FreeWili 2 with firmware that has FPGA BSP support
   (the `h\f` menu), connected over USB (`tools/fwfpga status` answers; use
   `--port <port>` if auto-detect picks the wrong one; only one program may
   hold the port). FPGA powered: `h\p\s 6 1`. Something to observe the header
   pins your design drives: LEDs, a meter or a logic analyzer.

2. **Baseline.** Record before touching anything:

   ```sh
   tools/fwfpga status            # expect source stock (or the previous design), cdone 1, clock 31244914 for stock (the design's rate otherwise)
   tools/fwfpga reg r 0x02 2      # stock: 6D 01
   tools/fwfpga reg r 0x70 16     # stock: 16 x 00
   ```

3. **Container check and upload.**

   ```sh
   tools/fwfpga inspect build/designs/<name>/<name>.fwfpga
   tools/fwfpga install <name>    # refuses anything that is not a container whose header equals design.toml
   ```

4. **Load.** `tools/fwfpga load <name>`. Expect
   `design_id <id>  version <v>  cdone 1  load_ms ~273`. Anything else is a
   token naming the failed check (`header:no-file`, `header:not-a-fwfpga`,
   `header:header-crc`, `bitstream-crc`, `idblock:<field>`, `cdone`, `arm`,
   `clock-code-unsupported`); record it verbatim and check
   `status` shows stock recovered (`source stock`, error field = the token).

5. **Status, ID block, directions.**

   ```sh
   tools/fwfpga status            # source file, armed 1, cdone 1, id/version/caps/profile match design.toml, error -, contention -
   tools/fwfpga reg r 0x70 16     # 46 57 32 46 01 <id> <ver> <caps> 00 <profile LE> <xor>; compare with `inspect`
   tools/fwfpga reg r 0x02 2      # direction bytes derived from the profile (template 6C 02, hello_regs 6C 03)
   tools/fwfpga reg r 0x0F        # 01 = armed, no reset since arm
   ```

6. **Stimulate and observe.** For each `FPGA_OUT` signal, change it and check
   the header pin (and that no other pin changed):

   ```sh
   tools/fwfpga reg w 0x10 0x01
   ```

   Also check the stock behaviour the profile promises: `PASS_*` signals still
   pass (`i\g\s n` / `i\g\l n` on an RP-driven header pin moves the pin), the
   I2C pair is unaffected, and the `i\g\u` word is as expected.

7. **Edge cases worth one line each**, when time allows: FPGA power cycle
   (`h\p\s 6 0`, `h\p\s 6 1`) — status must show your design re-armed; a
   reload of the same file; `tools/fwfpga restore` then load again.

8. **Restore.** `tools/fwfpga restore` -> `Ok`; `status` -> `source stock`;
   `tools/fwfpga reg r 0x02 2` -> `6D 01`.

9. **Record the result** in the design's README (Verify section): firmware
   version, every command with the reply quoted
   as the device sent it, what you observed on the header, and what the run
   does **not** demonstrate (contention, timing, anything you skipped).
   Record failures and anomalies; they are the valuable part.

10. **Run the tests.** `py -3 -m pytest tests tools/tests -q`.

## What a header observation proves

A pin seen at the expected level proves the header pin reached a level the
level shifter and your probe accept on the **outer** net. It proves nothing
about contention, drive strength, timing or the inner RP2350 <-> FPGA net. A
logic analyzer on the header across a load is the way to check that no two
drivers overlap. Remember that header GPIO26 and GPIO27 go high during every
load (`docs/io-direction.md`); do not read that as your design misbehaving.

## Reference

- `docs/io-direction.md` — the lifecycle phases you are exercising.
- `docs/fpga-design-contract.md` — the rules every design meets.
- `AGENTS.md` "Report honestly".
