# The FW2 FPGA design contract

The rules every bitfile for the FreeWili 2 obeys. Each rule says what it
guarantees, shows where it lives in the code, and says plainly what it cannot
prove. Contract version **1** (ID block byte 0x74).

Vocabulary: the **inner net** is RP2350 pin <-> FPGA `_Rp` pad; the **outer
net** is FPGA `_Out` pad <-> level shifter <-> header pin. The **profile** is
the ten-entry mode table in `design.toml [io_profile]`. **Armed** means
register 0x0F bit 0 = 1.

---

### Rule 1. The top is `fw2_shell`; user logic lives in `user_core` with the fixed port list.

```verilog
// designs/<name>/user_core.v
module user_core ( input wire clk, input wire rst_n,
  input wire [9:0] hdr_in, output wire [9:0] hdr_out, output wire [9:0] hdr_oe,
  input wire [9:0] rp_in,  output wire [9:0] rp_out,
  input wire [6:0] reg_addr, input wire [7:0] reg_wdata, input wire reg_wr, input wire reg_rd,
  output wire [7:0] reg_rdata,
  input wire [7:0] fifo_tx_data, input wire fifo_tx_valid, output wire fifo_tx_ready,
  output wire [7:0] fifo_rx_data, output wire fifo_rx_valid, input wire fifo_rx_ready );
```

`fpga/shell/fw2_user_core.vh` is the normative list; `fw2_shell` instantiates
`user_core` by name, so a missing or extra port is a synthesis error. No design
file may contain a pad name from `fpga/constraints/fw2.pcf`
(`check_design.py` checks).

*What this cannot prove:* that the user core's logic is sensible, or that it
meets timing (rule 5 does that).

### Rule 2. Every design declares `design.toml`, and everything is generated from it.

```toml
[design]
name = "hello_blink"  description = "..."  version = "001"  design_id = 2
kind = "user"  clock_hz = 31250000  capabilities = ["IO_BUFFER"]  repository = "wilifpga"
[io_profile]
spi_miso = "PASS_IN"  ...  gpio26 = "FPGA_OUT"  gpio27 = "PASS_OUT"
```

`fwfpga build` turns it into `fw2_design_id.vh` (the defines `fw2_shell.v`
includes) and into the `.fwfpga` header; `version` is exactly three digits,
hand-bumped; `design_id` is unique across `designs/*` (65535 is the stock
image).

*What this cannot prove:* that the description matches what the design does.

### Rule 3. Only `.fwfpga` containers load, and header must match fabric.

```text
firmware: parse header -> verify CRCs -> CRESET -> bitstream -> CDONE
          -> read 0x70..0x7F -> compare id/version/caps/clock/profile with header
          -> only then IO_ARM = 1
```

The ID block (`fw2_shell.v`, case on `bus_addr[3:0]`) is read-only and built
from the same constants as the pads: the packed profile at 0x7B-0x7E is
assembled from the per-signal defines that drive `fw2_io_buffer`, so the fabric
cannot report a direction it does not implement. `tb_shell` checks the 16 bytes
and the XOR checksum; a wrong `FW2_DESIGN_CHECKSUM` fails the simulation.

*What this cannot prove:* a hand-forged container whose header and fabric agree
but whose user core misbehaves; or the single-digit-millisecond window in which
a non-shell bitstream can drive pads before the firmware reads a bad ID block.

### Rule 4. Directions come only from the profile.

```verilog
// fpga/shell/fw2_io_buffer.v (per signal, compile-time MODE)
assign rp_oe[i]      = cfg ? IS_MISO : (arm & (rp_pass | rp_link));
assign hdr_oe_pad[i] = arm & ((hdr_pass & ~cfg) | hdr_user);
assign dir_bits[i]   = (MODE == PASS_OUT) | (MODE == FPGA_OUT);
```

No register changes a direction: writes to 0x02/0x03 are ignored and read back
the profile, HSBDIO (0x04) is absent. Every pad is an explicit `SB_IO`
(`fpga/shell/fw2_pad.v`) so a compile-time "input" can never be folded into a
driven constant by synthesis; `fpga/sim/check_netlist_pads.py` verifies that on
the synthesised netlist of every build. `hdr_oe` from the user core is honoured
only where `MODE == FPGA_OUT`; `rp_out` only where `MODE == LINK_F2RP`. The
shell ties every other pad off.

*What this cannot prove:* contention on the far side of the shifter (an
external device driving a header pin the profile calls `FPGA_OUT`), or that the
firmware set the RP2350 pin and shifter DIR to match (that is the firmware's
load sequence, `docs/io-direction.md`).

### Rule 5. Timing is met at `clock_hz`; lint is clean.

```sh
nextpnr-ice40 --up5k --package sg48 --pcf fpga/constraints/fw2.pcf --json X.json --asc X.asc --freq 31.25 --report report.json
verilator --lint-only -Wall -Ifpga/shell -Idesigns/<name> --top-module fw2_shell fpga/shell/fw2_lint.vlt <shell sources> designs/<name>/user_core.v
```

`nextpnr-ice40 --freq` fails the build on a violation (no
`--timing-allow-fail` for user designs; `--ignore-loops` is forbidden). The
only verilator waivers are in `fpga/shell/fw2_lint.vlt` and each is explained
there (`PROCASSINIT` for the iCE40 register-init idiom, width/style warnings
inside the unmodified `fpga/lib/spi_slave/spi_slave.v`, and `UNOPTFLAT` on the
passthrough pad pairs in `fw2_shell.v`).

*What this cannot prove:* behaviour of the two asynchronous inputs
(`IO_CONFIG_ENABLE`, the SPI pins are synchronised inside `spi_slave`) or the
SCK ceiling of the register bus (5 MHz at 31.25 MHz, measured in simulation).

### Rule 6. Never NVCM.

```text
Firmware NVCM/OTP functions: not referenced by any tool or design in this BSP.
```

The stock gateware bundled in the firmware stays restorable by the
FPGA menu's restore command, by a power cycle and by the firmware's own failure
handling. Nothing in `fpga/`, `designs/` or `tools/` writes non-volatile
configuration.

*What this cannot prove:* anything about code outside this repository.

### Rule 7. Designs tolerate firmware traffic.

```text
IO_CONFIG_EN toggles  -> SPI inner nets switch to the register bus and back
reads of 0x02/0x03    -> profile-derived bytes
reads in 0x10..0x5F   -> your registers answer
```

The firmware may read the shell and your registers at any time, so keep reads
free of side effects except where you mean them (`reg_rd`).

*What this cannot prove:* that your registers are safe to read at any moment;
that is your design's job.

### Rule 8. Container sanity.

```text
check_container.py: magic, header CRC32, bitstream CRC32 + SHA-256, 0x7EAA997E preamble,
                    size bounds, header fields == design.toml   (after build and before install)
```

The ID block is what the container header is compared against.

*What this cannot prove:* that the bitstream was built from the sources in the
repository (no reproducible-build check).

### Rule 9. The shell boots disarmed.

```verilog
// fpga/shell/fw2_shell.v
reg io_arm = 1'b0;                      // iCE40 power-up value, also cleared on resetn
always @(posedge CLK)
  if (resetn == 1'b0) begin if (io_arm) reset_since_arm <= 1'b1; io_arm <= 1'b0; end
  else if (wr_strobe && bus_addr == `FW2_REG_IO_ARM) begin io_arm <= bus_wdata[0]; reset_since_arm <= 1'b0; end
```

From CDONE until the firmware writes `IO_ARM = 1` every `_Rp`/`_Out` pad is an
input and both DIR balls read 0 (toward board); the only exception is
`SPI_MISO_Rp`, driven by the register bus and only while `IO_CONFIG_ENABLE` is
high. Register 0x01 or `IO_ARM = 0` returns everything to Z; a reset while armed
leaves the sticky flag in 0x0F bit 1 for the firmware's recovery path. The user
core cannot bypass this: it only sees the `hdr_*`/`rp_*` bundles and the shell
ANDs their output enables with `io_arm`. `fpga/sim/tb_shell.v` proves it
against a user core that drives every output it has: all 20 pads Z before arm
(also inside the window, except MISO_Rp), exactly the profile's outputs after
arm, Z again after 0x01 with 0x0F = 0x02, Z again after `IO_ARM = 0` with 0x0F =
0x00; `I2C_SDA` and the other unused pads stay Z before and after arm
(`check_netlist_pads.py` checks every pad at netlist level).

*What this cannot prove:* the pads while the FPGA is in reset or configuring,
before the shell exists. Header GPIO27 then goes high for about 200-250 ms and
header GPIO26 for about 30-100 ms on every load (`docs/io-direction.md`); never connect anything to them that a high level
during a load would harm. Once armed, the sticky registers 0x0D/0x0E
(`CONTENTION`, `docs/drivers/shell.md` section 4) report any `FPGA_OUT` pad
whose readback disagreed with the driven value for `FW2_CONT_FILTER`
consecutive clocks (default 32), so a shifter or header device fighting the FPGA is
detectable by the firmware after the fact, though not prevented.
