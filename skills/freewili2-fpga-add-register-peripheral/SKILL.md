---
name: freewili2:fpga-add-register-peripheral
description: Use when adding host-controllable registers to a FreeWili 2 FPGA design (wilifpga) — decoding the user register window 0x10-0x5F in user_core.v with the reg_wr/reg_rd strobes, writing the unit testbench, and the host-side fwfpga reg r/w sequence that drives it.
---

# freewili2:fpga-add-register-peripheral

Give a `user_core` a register interface the host can read and write with
`fwfpga reg r/w` (wire `h\f\r` / `h\f\w`), following the pattern
of `designs/hello_regs`.

## Procedure

1. **Allocate addresses** in 0x10-0x5F (80 bytes). Keep control registers
   contiguous so one burst writes them; put read-only status after them.
   Document the map in `design.toml [registers]` and the README's Registers
   table. 0x00-0x0F, 0x60-0x6F and 0x70-0x7F belong to the shell.

2. **Decode absolute addresses.** `reg_addr[6:0]` is the bus address itself.

   ```verilog
   localparam [6:0] REG_CTRL = 7'h10, REG_STAT = 7'h11;
   reg [7:0] ctrl = 8'h00;
   always @(posedge clk) begin
     if (!rst_n) ctrl <= 8'h00;                       // power-up and register 0x01 reset
     else if (reg_wr && reg_addr == REG_CTRL) ctrl <= reg_wdata;   // one-clock strobe
   end
   ```

   A block of 2^n registers: `wire in_regs = (reg_addr[6:3] == REG_BASE[6:3]);`
   then `regs[reg_addr[2:0]]` (hello_regs).

3. **Make `reg_rdata` combinational.** The shell samples it when the SPI slave
   loads the next byte; a registered version lags one byte.

   ```verilog
   always @(*) begin
     if      (reg_addr == REG_CTRL) reg_rdata = ctrl;
     else if (reg_addr == REG_STAT) reg_rdata = {7'b0, level};
     else                           reg_rdata = 8'h00;    // every unused address reads 0
   end
   ```

4. **Read side effects only through `reg_rd`.** It pulses one clock after a
   data byte has been shifted out, with `reg_addr` holding that byte's address.
   Use it to pop, acknowledge or count (`hello_regs` counts reads of 0x17 in
   0x19). Never clear state in the read mux itself: the firmware reads at times
   you do not control.

5. **Remember the burst semantics.** Reads and writes auto-increment, so
   `fwfpga reg r 0x10 8` and `fwfpga reg w 0x10 01 02 03` cover consecutive
   addresses; design multi-byte values little-endian and contiguous. Only
   0x60/0x61 hold their address.

6. **Drive header pins from register bits** only where the profile says
   `FPGA_OUT`:

   ```verilog
   assign hdr_out = ({9'b0, ctrl[0]} << `FW2_SIG_GPIO26) | ({9'b0, ctrl[1]} << `FW2_SIG_GPIO27);
   assign hdr_oe  = (10'b1 << `FW2_SIG_GPIO26) | (10'b1 << `FW2_SIG_GPIO27);
   ```

   Bits for other slots are ignored by the shell (rule 4); do not set them.

7. **Testbench** (`designs/<name>/tb/tb_user_core.v`): instantiate
   `user_core`, drive `reg_addr`, `reg_wdata`, pulse `reg_wr` one clock, check
   `reg_rdata` and the `hdr_out` bit; pulse `reg_rd` at an address with a side
   effect and check the counter; `$fatal` on mismatch, print `PASS`.
   `tools/fwfpga sim <name>` exits 1 on `$fatal`/`ERROR`.

8. **Lint and build**: `tools/fwfpga lint <name>` (fold unused inputs into the
   `unused` wire), `tools/fwfpga build <name>` (bump `version` in
   `design.toml` when the map changed).

9. **Host sequence** (board on zone 6, design installed and loaded):

   ```sh
   tools/fwfpga reg w 0x10 0x03          # CLI normalises to `h\f\w 10 03`; `0x` never reaches the wire
   tools/fwfpga reg r 0x10               # -> 03
   tools/fwfpga reg r 0x10 8             # burst
   tools/fwfpga reg w 0x10 0102030405060708   # hex string = 8 bytes
   # the FPGA_OUT header pins follow the bits (hello_regs: GPIO26/27); check with an LED, meter or analyzer
   ```

   hello_regs on hardware: `reg w 0x10 0x03` -> `Ok`, readback `03`, both
   pins high; `reg r 0x18 2` -> `03 00` after three writes. Record yours in
   the design's README (`freewili2:fpga-bringup-verify`).

10. **Host script (optional).** A `designs/<name>/host/*.py` that opens the
    MAIN port (USB VID 093C PID 205A, 115200, `0x03` to the root, replies
    framed `[<path> <ts> <seq> <payload> <0|1>]`) or shells out to
    `tools/fwfpga reg`, and asserts expected values; `check_design` does not
    scan `host/`.

## Gotchas

- `Invalid` from the device = a `0x` on the wire (hand-typed).
- Values one address off = you decoded an offset, or assumed the write
  pre-decrement is visible. It is not.
- Second byte of a burst equals the first = SCK above the 5 MHz simulated
  ceiling or a registered `reg_rdata`.
- Registers read 0 after a zone-6 cycle: fabric state is lost with the rail;
  the firmware reloads the design, not your registers.
- 0x0F bit 1 set = a reset (0x01) happened since the last arm; the shell is
  disarmed and your outputs are Z until the firmware re-arms.

## Reference

- `docs/drivers/shell.md` sections 2 and 5 — burst semantics, strobe timing.
- `docs/learn/02-registers.md` — the tutorial version of this skill.
- `designs/hello_regs/user_core.v`, `tb/tb_user_core.v`, `README.md`.
- `fpga/shell/fw2_user_core.vh`, `fw2_regs.vh`, `fw2_profile.vh`.
