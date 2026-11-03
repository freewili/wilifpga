# Learn 02 — Registers: `hello_regs`

**What you learn.** How host register writes and reads reach your
`user_core`, how bursts work, and what the `reg_wr` / `reg_rd` strobes are
for.

**You need.** Tutorial 01 done.

## 1. The design

`designs/hello_regs/`: eight read/write registers and two `FPGA_OUT` pins.

| addr | R/W | contents |
|---|---|---|
| 0x10-0x17 | RW | scratch registers; 0x10 bit 0 drives GPIO26, bit 1 GPIO27 |
| 0x18 | R | number of writes into 0x10-0x17 |
| 0x19 | R | number of reads of 0x17 (the `reg_rd` example) |
| 0x1A | R | XOR of the eight registers |

## 2. How `user_core` sees the bus

- `reg_addr` is the **absolute** address (0x10, not 0). Your core only sees
  0x10-0x5F.
- `reg_wr` is high for **one clock** with the written byte on `reg_wdata`:

  ```verilog
  if (reg_wr && in_regs) begin regs[reg_addr[2:0]] <= reg_wdata; wr_count <= wr_count + 8'd1; end
  ```

- `reg_rdata` must be **combinational** in `reg_addr` and your state
  (`assign` or `always @(*)`).
- `reg_rd` is high for one clock after a byte has been read, with
  `reg_addr` still on that byte. Use it for read side effects (pop a queue,
  clear a flag); keep every other read free of side effects, because the
  firmware may read your registers at any time.
- Bursts auto-increment: `reg r 0x10 8` returns 0x10..0x17.
- `rst_n` is low at power-up and after a write of 0x01 to register 0x01.

## 3. Build, load, talk to it

```sh
tools/fwfpga build hello_regs && tools/fwfpga install hello_regs && tools/fwfpga load hello_regs
tools/fwfpga reg w 0x10 0x03      # GPIO26 and GPIO27 high
tools/fwfpga reg w 0x10 0x00      # both low
tools/fwfpga reg w 0x10 01 02 03 04 05 06 07 08
tools/fwfpga reg r 0x10 8         # 01 02 03 04 05 06 07 08
tools/fwfpga reg r 0x1A           # XOR = 08
tools/fwfpga restore
```

## 4. Write your own

One `always @(posedge clk)` block with `if (!rst_n)` first, one `if (reg_wr &&
reg_addr == ...)` per register, one combinational `reg_rdata` mux, and
`hdr_out` / `hdr_oe` only for the signals your profile marks `FPGA_OUT` (use
the `FW2_SIG_*` indices from `fpga/shell/fw2_profile.vh`). Tie unused outputs
to 0. `skills/freewili2-fpga-add-register-peripheral/SKILL.md` is the
checklist, including the testbench pattern.

## What can go wrong

- **Writes land one address off:** you decoded an offset; `reg_addr` is
  absolute.
- **A read returns the previous byte's value:** `reg_rdata` is registered;
  make it combinational.
- **Registers back at 0:** zone 6 was switched off; the design reloads but
  starts from reset.

Next: `03-streaming.md`.
