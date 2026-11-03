# IO direction — what the firmware does around a load

Each of the ten header signals has an inner net (RP2350 pin ↔ FPGA `_Rp`
pad) and an outer net (FPGA `_Out` pad ↔ level shifter ↔ header pin). The
level shifter has no output enable, so a direction set wrong for the design
means two drivers on one wire. That is why a design's directions travel with
it in the `.fwfpga` file and why nothing drives a pin until the design has
been checked.

## The load sequence

When you run `fwfpga load` (firmware `h\f\l`), the firmware:

1. **Disarms** the running design: the shell releases every pin.
2. **Sets the RP2350 pins to inputs**, with pulls off, before anything else
   moves.
3. **Sets the level shifters** from the new file's `[io_profile]`: toward the
   header for `FPGA_OUT` and `PASS_OUT`, toward the board for everything else.
4. **Programs the FPGA.** The new design starts disarmed, with every pin an
   input.
5. **Checks the design**: the ID block the fabric reports must match the
   file's header field for field. On a mismatch it restores the stock
   gateware.
6. **Arms the design** (`IO_ARM`), and only then turns on the RP2350 outputs
   the profile asks for (`PASS_OUT`, `LINK_RP2F`).

Any failure, a configuration loss or an FPGA power cycle goes back through
the same steps, with the stock gateware or the last requested design. While a
custom design is armed, the board's own IO-direction menu settings are
suspended; they come back with `fwfpga restore`.

## GPIO26 and GPIO27 during a load

The direction of these two shifters comes from the FPGA itself, so nothing
holds it while the FPGA is in reset or being programmed. During every load,
header **GPIO27 goes high for about 200–250 ms** and header **GPIO26 for about
30–100 ms**. Do not connect anything to them that a high level or a stray
edge during a load would harm, and do not drive them from an external
push-pull output across a load.

## What this cannot protect against

A device on the header driving a pin your profile calls `FPGA_OUT`. The
profile decides the board side; what you wire to the header is up to you.

Register-level detail of the direction bits and the arm gate:
`docs/drivers/shell.md`. Mode table: `AGENTS.md`.
