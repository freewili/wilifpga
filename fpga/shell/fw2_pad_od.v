// ---------------------------------------------------------------------------
// fw2_pad_od.v - open-drain pad wrapper around fw2_pad (new code, 2026).
// ---------------------------------------------------------------------------
// Open-drain variant for I2C_SDA: pulls low while pull_low = 1, otherwise Z.
// Never a 1 driver. A design with the I2C_SLAVE capability gets pull_low from
// the i2c_slave; the v1 shell ties it to 0.
module fw2_pad_od
(
  inout  wire pad,
  input  wire pull_low,
  output wire i
);

fw2_pad u_pad (.pad(pad), .o(1'b0), .oe(pull_low), .i(i));

endmodule
