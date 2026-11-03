// ---------------------------------------------------------------------------
// fw2_pad.v - explicit bidirectional pad for fw2_shell (new code, 2026).
//
// Why this exists: yosys folds `assign PAD = 1'bz;` and `assign PAD = 1'b0 ?
// x : 1'bz;` (an output enable that is a compile-time 0) into a CONSTANT that
// drives the pad. Found on hardware 2026-10-31: the parked I2C_SDA pad of
// hello_blink drove header SDA low (MAIN read GPIO16 = 0, the header LED went
// off). The same fold applies to every OFF / FPGA_IN inner net whose enable is
// a constant 0 after the profile is baked in.
//
// Under synthesis this module instantiates the iCE40 SB_IO primitive with
// PIN_TYPE 6'b1010_01 (non-registered tri-state output + non-registered input)
// and (* keep *), so the output enable always reaches the pad's OE, constant or
// not, and OE = 0 is a true high-impedance input. In simulation and lint
// (SYNTHESIS undefined) it is the plain tri-state assign the testbenches check.
// ---------------------------------------------------------------------------

module fw2_pad
(
  inout  wire pad,
  input  wire o,      // value driven while oe = 1
  input  wire oe,     // 1 = drive, 0 = high impedance (input)
  output wire i       // pad level
);

`ifdef SYNTHESIS
  (* keep *)
  SB_IO #(
    .PIN_TYPE(6'b1010_01),   // PIN_OUTPUT_TRISTATE | PIN_INPUT
    .PULLUP(1'b0)
  ) u_io (
    .PACKAGE_PIN(pad),
    .OUTPUT_ENABLE(oe),
    .D_OUT_0(o),
    .D_IN_0(i)
  );
`else
  assign pad = oe ? o : 1'bz;
  assign i   = pad;
`endif

endmodule

