// ---------------------------------------------------------------------------
// tb_shell.v - FW2 shell testbench (iverilog -g2012). Checks against the
// design-ID include on the include path (fpga/sim/tb_design by default) and
// the test user core in fpga/sim/tb_design/user_core.v:
//   1. ID block readback (0x70-0x7F) and XOR checksum; packed profile equals
//      FW2_DESIGN_IO_PROFILE
//   2. 0x02/0x03 direction readback equals the profile; writes are ignored
//   3. user register window round trip (burst write / burst read, auto-increment)
//      and the reg_rd strobe
//   4. stream FIFO: pattern burst FPGA -> host (hold-address on 0x61), count,
//      status flags, host -> FPGA burst on 0x60
//   6. I2C_SDA (open drain) and the PSRAM data pads are Z before and after arm
//      unless the I2C_SLAVE capability is set
//   5. ARM gate: every pad Z before arm (user core drives everything), only
//      MISO_Rp inside IO_CONFIG_ENABLE; after IO_ARM=1 exactly the profile's
//      outputs drive; after reg 0x01 they are Z again and 0x0F reports the
//      sticky flag; IO_ARM=0 also releases
//   7. pad-readback contention flags 0x0D/0x0E: a header-side driver fighting
//      an FPGA_OUT pad for >= 4 clocks sets the signal's bit (both bytes,
//      both polarities), the byte clears on its own read only, 2 and 3 clocks
//      do not set it, non-FPGA_OUT signals never set it, disarm and reset
//      clear it, reads while disarmed are 0
// Every failure is a $fatal.
// Run: iverilog -g2012 -I fpga/shell -I fpga/sim/tb_design -o build/sim/tb_shell.vvp
//        fpga/sim/tb_shell.v fpga/sim/spi_bus_bfm.v fpga/shell/*.v
//        fpga/lib/spi_slave/spi_slave.v fpga/lib/fw2_stream_fifo/fw2_stream_fifo.v
//        fpga/sim/tb_design/user_core.v  && vvp build/sim/tb_shell.vvp
// ---------------------------------------------------------------------------
// Section 7 exercises the contention detector's filter edge (2/3/4-clock
// fights), so the tb pins the filter at 4 clocks; the shell's default is
// 32 (fw2_shell.v, CONT_FILTER). This define reaches the shell sources
// because iverilog compiles tb_shell.v first in the same unit.
`define FW2_CONT_FILTER 4
`timescale 1ns/1ps
`include "fw2_profile.vh"
`include "fw2_regs.vh"
`include "fw2_design_id.vh"

module tb_shell;

// Override with iverilog -Ptb_shell.SCK_HALF_NS=<ns> to probe the SPI clock ceiling
parameter real SCK_HALF_NS = 153.8;   // 3.25 MHz SCK (firmware default)
localparam real CLK_HALF_NS = 16.0;   // 31.25 MHz
localparam [29:0] PROFILE = `FW2_PACK_PROFILE;

reg CLK = 1'b0;
always #(CLK_HALF_NS) CLK = ~CLK;

// Pads, indexed like the bundles (0 spi_miso .. 9 gpio27)
wire [9:0] rp_pad;
wire [9:0] hdr_pad;
wire GPIO_26_Dir, GPIO_27_Dir;
wire I2C_SDA;
wire SRAM_CLK, SRAM_CS, SRAM_IO0, SRAM_IO1, SRAM_IO2, SRAM_IO3, CM0_RX0, CM0_CTS0;

// Testbench-side pad drivers (external devices / RP2350 GPIO)
reg [9:0] tb_rp_oe = 10'd0,  tb_rp_val = 10'd0;
reg [9:0] tb_hdr_oe = 10'd0, tb_hdr_val = 10'd0;
// A header-side device fighting an FPGA-driven _Out pad (section 7). Supply
// strength so it wins the resolution against the pad's strong driver, which is
// what a level shifter or an external driver does to the FPGA pad on the board.
reg [9:0] tb_fight_oe = 10'd0, tb_fight_val = 10'd0;
genvar k;
generate
  for (k = 0; k < 10; k = k + 1) begin : g_tbdrv
    assign rp_pad[k]  = tb_rp_oe[k]  ? tb_rp_val[k]  : 1'bz;
    assign hdr_pad[k] = tb_hdr_oe[k] ? tb_hdr_val[k] : 1'bz;
    assign (supply1, supply0) hdr_pad[k] = tb_fight_oe[k] ? tb_fight_val[k] : 1'bz;
  end
endgenerate

// SPI register master on the inner SPI1 nets
wire bfm_sclk, bfm_mosi, bfm_cs, io_cfg_en;
assign rp_pad[`FW2_SIG_SPI_SCLK] = bfm_sclk;
assign rp_pad[`FW2_SIG_SPI_MOSI] = bfm_mosi;
assign rp_pad[`FW2_SIG_SPI_CS]   = bfm_cs;

spi_bus_bfm #(.HALF_NS(SCK_HALF_NS)) bfm (
  .sclk(bfm_sclk), .mosi(bfm_mosi), .miso(rp_pad[`FW2_SIG_SPI_MISO]), .cs(bfm_cs), .io_cfg_en(io_cfg_en)
);

fw2_shell dut (
  .SPI_MISO_Rp(rp_pad[0]), .SPI_CS_Rp(rp_pad[1]), .SPI_Clk_Rp(rp_pad[2]), .SPI_MOSI_Rp(rp_pad[3]),
  .UART_Tx_Rp(rp_pad[4]), .UART_Rx_Rp(rp_pad[5]), .UART_CTS_Rp(rp_pad[6]), .UART_RTS_Rp(rp_pad[7]),
  .GPIO_26_Rp(rp_pad[8]), .GPIO_27_Rp(rp_pad[9]),
  .SPI_MISO_Out(hdr_pad[0]), .SPI_CS_Out(hdr_pad[1]), .SPI_Clk_Out(hdr_pad[2]), .SPI_MOSI_Out(hdr_pad[3]),
  .UART_Tx_Out(hdr_pad[4]), .UART_Rx_Out(hdr_pad[5]), .UART_CTS_Out(hdr_pad[6]), .UART_RTS_Out(hdr_pad[7]),
  .GPIO_26_Out(hdr_pad[8]), .GPIO_27_Out(hdr_pad[9]),
  .CLK(CLK),
  .I2C_SDA(I2C_SDA), .I2C_SCL(1'b1),
  .IO_CONFIG_ENABLE(io_cfg_en),
  .GPIO_26_Dir(GPIO_26_Dir), .GPIO_27_Dir(GPIO_27_Dir),
  .SRAM_CLK(SRAM_CLK), .SRAM_CS(SRAM_CS),
  .SRAM_IO0(SRAM_IO0), .SRAM_IO1(SRAM_IO1), .SRAM_IO2(SRAM_IO2), .SRAM_IO3(SRAM_IO3),
  .CM0_SPI0_MISO(1'b0), .CM0_SPI0_CLK(1'b0), .CM0_RX1(1'b1), .CM0_SPI1_MISO(1'b1), .CM0_SPI1_CLK(1'b0),
  .CM0_RX0(CM0_RX0), .CM0_CTS0(CM0_CTS0)
);

// ------------------------------------------------------------------ helpers
integer errors = 0;
integer checks = 0;

task check(input cond, input [8*64-1:0] msg);
begin
  checks = checks + 1;
  if (!cond) begin
    errors = errors + 1;
    $display("FAIL @%0t: %0s", $time, msg);
    $fatal(1, "tb_shell: check failed");
  end
end
endtask

task check_eq(input [7:0] got, input [7:0] exp, input [8*64-1:0] msg);
begin
  checks = checks + 1;
  if (got !== exp) begin
    errors = errors + 1;
    $display("FAIL @%0t: %0s got 0x%02x expected 0x%02x", $time, msg, got, exp);
    $fatal(1, "tb_shell: check failed");
  end
end
endtask

function [2:0] mode_of(input integer sig);
  mode_of = PROFILE[3*sig+2 -: 3];
endfunction

function dir_bit(input integer sig);
  dir_bit = (mode_of(sig) == `FW2_MODE_PASS_OUT) || (mode_of(sig) == `FW2_MODE_FPGA_OUT);
endfunction

// Every header pad and every inner pad must be Z (tb drivers off, BFM released)
task check_all_z(input [8*64-1:0] why);
  integer s;
begin
  for (s = 0; s < 10; s = s + 1) begin
    checks = checks + 2;
    if (rp_pad[s] !== 1'bz) begin
      $display("FAIL @%0t: rp_pad[%0d] driven (%b) while %0s", $time, s, rp_pad[s], why);
      $fatal(1, "tb_shell: pad driven while disarmed");
    end
    if (hdr_pad[s] !== 1'bz) begin
      $display("FAIL @%0t: hdr_pad[%0d] driven (%b) while %0s", $time, s, hdr_pad[s], why);
      $fatal(1, "tb_shell: pad driven while disarmed");
    end
  end
  check(GPIO_26_Dir === 1'b0, "GPIO_26_Dir must be toward board (0) while disarmed");
  check(GPIO_27_Dir === 1'b0, "GPIO_27_Dir must be toward board (0) while disarmed");
  check_parked_pads;
end
endtask

// I2C_SDA is open-drain and must never be driven unless the design has the
// I2C_SLAVE capability (none in v1); the PSRAM data pads stay inputs.
// Checked before and after arm. (Found on hardware: a constant-Z assign was
// folded by yosys into a driven 0 on SDA; fw2_pad prevents it, and
// fpga/sim/check_netlist_pads.py checks the synthesised netlist.)
task check_parked_pads;
begin
  if (!(`FW2_DESIGN_CAPS & (8'h01 << `FW2_CAP_I2C_SLAVE)))
    check(I2C_SDA === 1'bz, "I2C_SDA must be Z without the I2C_SLAVE capability");
  check(SRAM_IO0 === 1'bz && SRAM_IO1 === 1'bz && SRAM_IO2 === 1'bz && SRAM_IO3 === 1'bz, "SRAM_IO pads must be Z");
  check(SRAM_CS === 1'b1 && SRAM_CLK === 1'b0, "PSRAM deselected, clock idle");
  check(CM0_RX0 === 1'b1 && CM0_CTS0 === 1'b1, "CM0 UART nets idle high");
end
endtask

// After arm: exactly the profile's outputs drive, with the user core driving
// all ones and the tb driving the inputs of PASS/LINK/FPGA_IN signals.
task check_armed_drivers(input [9:0] stim);
  integer s;
  reg [2:0] m;
begin
  tb_rp_oe = 10'd0; tb_hdr_oe = 10'd0;
  for (s = 0; s < 10; s = s + 1) begin
    m = mode_of(s);
    case (m)
      `FW2_MODE_PASS_OUT:  begin tb_rp_oe[s]  = 1'b1; tb_rp_val[s]  = stim[s]; end
      `FW2_MODE_PASS_IN:   begin tb_hdr_oe[s] = 1'b1; tb_hdr_val[s] = stim[s]; end
      `FW2_MODE_FPGA_IN:   begin tb_hdr_oe[s] = 1'b1; tb_hdr_val[s] = stim[s]; end
      `FW2_MODE_LINK_RP2F: begin tb_rp_oe[s]  = 1'b1; tb_rp_val[s]  = stim[s]; end
      default: ;
    endcase
  end
  #(10*CLK_HALF_NS);
  for (s = 0; s < 10; s = s + 1) begin
    m = mode_of(s);
    checks = checks + 2;
    case (m)
      `FW2_MODE_PASS_OUT: begin
        if (hdr_pad[s] !== stim[s]) begin $display("FAIL sig %0d PASS_OUT: hdr %b != %b", s, hdr_pad[s], stim[s]); $fatal(1); end
        // tb drives rp: no way to see Z, contention would show as x
        if (rp_pad[s] !== stim[s]) begin $display("FAIL sig %0d PASS_OUT: rp contention %b", s, rp_pad[s]); $fatal(1); end
      end
      `FW2_MODE_PASS_IN: begin
        if (rp_pad[s] !== stim[s]) begin $display("FAIL sig %0d PASS_IN: rp %b != %b", s, rp_pad[s], stim[s]); $fatal(1); end
        if (hdr_pad[s] !== stim[s]) begin $display("FAIL sig %0d PASS_IN: hdr contention %b", s, hdr_pad[s]); $fatal(1); end
      end
      `FW2_MODE_FPGA_OUT: begin
        if (hdr_pad[s] !== 1'b1) begin $display("FAIL sig %0d FPGA_OUT: hdr %b != 1 (user drives 1)", s, hdr_pad[s]); $fatal(1); end
        if (rp_pad[s] !== 1'bz) begin $display("FAIL sig %0d FPGA_OUT: rp must be Z, is %b", s, rp_pad[s]); $fatal(1); end
      end
      `FW2_MODE_FPGA_IN: begin
        if (rp_pad[s] !== 1'bz) begin $display("FAIL sig %0d FPGA_IN: rp must be Z, is %b", s, rp_pad[s]); $fatal(1); end
        if (hdr_pad[s] !== stim[s]) begin $display("FAIL sig %0d FPGA_IN: hdr contention %b", s, hdr_pad[s]); $fatal(1); end
      end
      `FW2_MODE_LINK_RP2F: begin
        if (hdr_pad[s] !== 1'bz) begin $display("FAIL sig %0d LINK_RP2F: hdr must be Z, is %b", s, hdr_pad[s]); $fatal(1); end
        if (rp_pad[s] !== stim[s]) begin $display("FAIL sig %0d LINK_RP2F: rp contention %b", s, rp_pad[s]); $fatal(1); end
      end
      `FW2_MODE_LINK_F2RP: begin
        if (rp_pad[s] !== 1'b1) begin $display("FAIL sig %0d LINK_F2RP: rp %b != 1 (user drives 1)", s, rp_pad[s]); $fatal(1); end
        if (hdr_pad[s] !== 1'bz) begin $display("FAIL sig %0d LINK_F2RP: hdr must be Z, is %b", s, hdr_pad[s]); $fatal(1); end
      end
      default: begin // OFF
        if (rp_pad[s] !== 1'bz || hdr_pad[s] !== 1'bz) begin $display("FAIL sig %0d OFF: pads must be Z (%b %b)", s, rp_pad[s], hdr_pad[s]); $fatal(1); end
      end
    endcase
  end
  check(GPIO_26_Dir === dir_bit(`FW2_SIG_GPIO26), "GPIO_26_Dir follows profile when armed");
  check(GPIO_27_Dir === dir_bit(`FW2_SIG_GPIO27), "GPIO_27_Dir follows profile when armed");
  check_parked_pads;
  tb_rp_oe = 10'd0; tb_hdr_oe = 10'd0;
  #(4*CLK_HALF_NS);
end
endtask

// Fight header pad `sig` with `level` for exactly `clocks` fabric clocks:
// the driver turns on and off at CLK falling edges, so exactly `clocks` rising
// edges see the disagreement. Then two idle clocks for the flag to register.
task fight(input integer sig, input level, input integer clocks);
begin
  @(negedge CLK);
  tb_fight_val[sig] = level;
  tb_fight_oe[sig]  = 1'b1;
  repeat (clocks) @(negedge CLK);
  tb_fight_oe[sig]  = 1'b0;
  #(4*CLK_HALF_NS);
end
endtask

// Fight every signal whose mode is not FPGA_OUT with `level` for `clocks` clocks
task fight_non_fpga_out(input level, input integer clocks);
  integer s;
begin
  @(negedge CLK);
  for (s = 0; s < 10; s = s + 1)
    if (mode_of(s) != `FW2_MODE_FPGA_OUT) begin tb_fight_val[s] = level; tb_fight_oe[s] = 1'b1; end
  repeat (clocks) @(negedge CLK);
  tb_fight_oe = 10'd0;
  #(4*CLK_HALF_NS);
end
endtask

// Read both contention bytes (window on, then off again so pads stay in play)
task read_contention(output [7:0] lo, output [7:0] hi);
begin
  bfm.io_config_en(1'b1);
  bfm.reg_read(`FW2_REG_CONTENTION, lo);
  bfm.reg_read(`FW2_REG_CONTENTION_GPIO, hi);
  bfm.io_config_en(1'b0);
  bfm.release_bus;
  #(4*CLK_HALF_NS);
end
endtask

// ------------------------------------------------------------------ test body
reg [7:0]  d, d2;
reg [7:0]  idb [0:15];
reg [7:0]  ck;
reg [31:0] prof_word;
integer    i, n;
reg [7:0]  exp_hi, exp_lo;

initial begin
  $display("tb_shell: design id %0d version %0d caps 0x%02x profile 0x%08x, SCK %0.2f MHz",
           `FW2_DESIGN_ID, `FW2_DESIGN_VERSION, `FW2_DESIGN_CAPS, `FW2_DESIGN_IO_PROFILE, 500.0/SCK_HALF_NS);
  #(20*CLK_HALF_NS);

  // ---- 5a. boot disarmed: nothing drives, even though the user core drives everything
  bfm.release_bus;
  #(10*CLK_HALF_NS);
  check_all_z("disarmed after power-up, IO_CONFIG_ENABLE low");
  bfm.io_config_en(1'b1);
  #(4*CLK_HALF_NS);
  check(rp_pad[`FW2_SIG_SPI_MISO] !== 1'bz, "MISO_Rp drives inside IO_CONFIG_ENABLE while disarmed");
  for (i = 1; i < 10; i = i + 1) begin
    check(rp_pad[i] === 1'bz, "only MISO_Rp may drive while disarmed in the window");
    check(hdr_pad[i] === 1'bz, "no header pad drives while disarmed in the window");
  end
  check(hdr_pad[0] === 1'bz, "MISO_Out does not drive while disarmed");
  bfm.hold_bus;

  // ---- 1. ID block
  bfm.burst_read(`FW2_REG_ID_BASE, 16);
  ck = 8'h00;
  for (i = 0; i < 16; i = i + 1) begin
    idb[i] = bfm.rx_buf[i];
    if (i < 15) ck = ck ^ idb[i];
  end
  check_eq(idb[0], `FW2_ID_MAGIC0, "ID magic F");
  check_eq(idb[1], `FW2_ID_MAGIC1, "ID magic W");
  check_eq(idb[2], `FW2_ID_MAGIC2, "ID magic 2");
  check_eq(idb[3], `FW2_ID_MAGIC3, "ID magic F");
  check_eq(idb[4], `FW2_CONTRACT_VERSION, "contract version");
  check_eq(idb[5], `FW2_DESIGN_ID & 8'hFF, "design id lo");
  check_eq(idb[6], (`FW2_DESIGN_ID >> 8) & 8'hFF, "design id hi");
  check_eq(idb[7], `FW2_DESIGN_VERSION & 8'hFF, "design version lo");
  check_eq(idb[8], (`FW2_DESIGN_VERSION >> 8) & 8'hFF, "design version hi");
  check_eq(idb[9], `FW2_DESIGN_CAPS, "capabilities");
  check_eq(idb[10], `FW2_DESIGN_CLOCK_CODE, "clock code");
  prof_word = {idb[14], idb[13], idb[12], idb[11]};
  check(prof_word == `FW2_DESIGN_IO_PROFILE, "ID block profile equals FW2_DESIGN_IO_PROFILE");
  check(prof_word == {2'b00, PROFILE}, "ID block profile equals the per-signal defines");
  check_eq(idb[15], ck, "checksum byte equals XOR of 0x70..0x7E");
  check_eq(idb[15], `FW2_DESIGN_CHECKSUM, "checksum byte equals FW2_DESIGN_CHECKSUM");
  // single reads agree with the burst (auto-increment semantics)
  bfm.reg_read(7'h75, d);
  check_eq(d, idb[5], "single read 0x75 == burst byte 5");
  bfm.reg_read(7'h7F, d);
  check_eq(d, idb[15], "single read 0x7F == burst byte 15");
  $display("  ID block ok: %02x %02x %02x %02x | id %0d ver %0d caps %02x clk %0d prof %08x ck %02x",
           idb[0], idb[1], idb[2], idb[3], {idb[6], idb[5]}, {idb[8], idb[7]}, idb[9], idb[10], prof_word, idb[15]);

  // ---- 2. direction readback (stock format) equals the profile; writes ignored
  exp_hi = {dir_bit(`FW2_SIG_UART_CTS), dir_bit(`FW2_SIG_SPI_SCLK), dir_bit(`FW2_SIG_SPI_CS), dir_bit(`FW2_SIG_SPI_MISO),
            dir_bit(`FW2_SIG_SPI_MOSI), dir_bit(`FW2_SIG_UART_TX), dir_bit(`FW2_SIG_UART_RX), dir_bit(`FW2_SIG_UART_RTS)};
  exp_lo = {6'b0, dir_bit(`FW2_SIG_GPIO26), dir_bit(`FW2_SIG_GPIO27)};
  bfm.burst_read(`FW2_REG_IODIR_HI, 2);
  check_eq(bfm.rx_buf[0], exp_hi, "reg 0x02 (readDir byte 0)");
  check_eq(bfm.rx_buf[1], exp_lo, "reg 0x03 (readDir byte 1)");
  bfm.tx_buf[0] = ~exp_hi; bfm.tx_buf[1] = ~exp_lo & 8'h03;
  bfm.burst_write(`FW2_REG_IODIR_HI, 2);   // stock writeDir sequence
  bfm.burst_read(`FW2_REG_IODIR_HI, 2);
  check_eq(bfm.rx_buf[0], exp_hi, "reg 0x02 unchanged after write (directions come only from the profile)");
  check_eq(bfm.rx_buf[1], exp_lo, "reg 0x03 unchanged after write");
  bfm.reg_read(`FW2_REG_HSBDIO, d);
  check_eq(d, 8'h00, "reg 0x04 HSBDIO reads 0");
  bfm.reg_read(`FW2_REG_IO_ARM, d);
  check_eq(d, 8'h00, "reg 0x0F reads 0 after power-up");
  $display("  direction readback ok: 0x%02x 0x%02x", exp_hi, exp_lo);

  // ---- 3. user register window
  for (i = 0; i < 8; i = i + 1) bfm.tx_buf[i] = 8'hA0 + i[7:0];
  bfm.burst_write(7'h10, 8);
  bfm.burst_read(7'h10, 8);
  for (i = 0; i < 8; i = i + 1) check_eq(bfm.rx_buf[i], 8'hA0 + i[7:0], "user reg burst round trip");
  bfm.reg_write(7'h13, 8'h5A);
  bfm.reg_read(7'h13, d);
  check_eq(d, 8'h5A, "user reg single write/read 0x13");
  bfm.reg_read(7'h12, d);
  check_eq(d, 8'hA2, "neighbour register untouched");
  bfm.reg_read(7'h24, d);     // first read: 0 hits before, strobe lands after
  bfm.reg_read(7'h24, d);
  check_eq(d, 8'h01, "reg_rd strobe counted once per read of 0x24");
  bfm.burst_read(7'h23, 3);   // 0x23, 0x24, 0x25 -> one more strobe on 0x24
  bfm.reg_read(7'h24, d);
  check_eq(d, 8'h03, "reg_rd strobe counted during burst");
  bfm.reg_read(7'h00, d);
  check_eq(d, 8'h00, "reg 0x00 reads 0");
  bfm.reg_read(7'h5F, d);
  check_eq(d, 8'h00, "unimplemented user reg 0x5F reads 0");
  $display("  user register window ok");

  // ---- 4. stream FIFO
  if (`FW2_DESIGN_CAPS & (8'h01 << `FW2_CAP_STREAM)) begin
    bfm.reg_read(`FW2_REG_FIFO_STAT, d);
    check_eq(d, 8'h85, "FIFO status: present, rx empty, tx empty");
    bfm.burst_read(`FW2_REG_FIFO_CNT0, 4);
    check(bfm.rx_buf[0] == 0 && bfm.rx_buf[1] == 0 && bfm.rx_buf[2] == 0 && bfm.rx_buf[3] == 0, "RX count 0");
    // FPGA -> host: 1000 bytes pattern from seed 0x37
    n = 1000;
    bfm.reg_write(7'h23, 8'h37);
    bfm.reg_write(7'h20, n[7:0]);
    bfm.reg_write(7'h21, n[15:8]);
    bfm.reg_write(7'h22, 8'h01);
    #(5*n*CLK_HALF_NS + 200);   // test core pushes one byte per two clocks
    bfm.burst_read(`FW2_REG_FIFO_CNT0, 4);
    check_eq(bfm.rx_buf[0], n[7:0], "RX count lo");
    check_eq(bfm.rx_buf[1], n[15:8], "RX count hi");
    bfm.reg_read(`FW2_REG_FIFO_STAT, d);
    check_eq(d, 8'h84, "FIFO status: rx not empty");
    bfm.burst_read(`FW2_REG_FIFO_RX, 600);          // hold-address burst
    for (i = 0; i < 600; i = i + 1) check_eq(bfm.rx_buf[i], 8'h37 + i[7:0], "RX burst pattern (first 600)");
    bfm.burst_read(`FW2_REG_FIFO_CNT0, 2);
    check_eq(bfm.rx_buf[0], 8'h90, "RX count after partial drain lo (400 = 0x190)");
    check_eq(bfm.rx_buf[1], 8'd1, "RX count after partial drain hi");
    bfm.burst_read(`FW2_REG_FIFO_RX, 400);
    for (i = 0; i < 400; i = i + 1) check_eq(bfm.rx_buf[i], 8'h37 + 8'd88 + i[7:0], "RX burst pattern (last 400)");
    bfm.reg_read(`FW2_REG_FIFO_STAT, d);
    check_eq(d, 8'h85, "FIFO drained: rx empty, no flags");
    // underrun: read one more
    bfm.reg_read(`FW2_REG_FIFO_RX, d);
    check_eq(d, 8'h00, "empty RX read returns 0x00");
    bfm.reg_read(`FW2_REG_FIFO_STAT, d);
    check_eq(d, 8'hC5, "RX underrun flag sticky");
    bfm.reg_read(`FW2_REG_FIFO_STAT, d);
    check_eq(d, 8'h85, "flags cleared by the status read");
    // overrun: a misbehaving core pushes 5000 bytes ignoring fifo_rx_ready (depth 4096)
    bfm.reg_write(7'h25, 8'h01);
    n = 5000;
    bfm.reg_write(7'h20, n[7:0]);
    bfm.reg_write(7'h21, n[15:8]);
    bfm.reg_write(7'h22, 8'h01);
    #(5*n*CLK_HALF_NS + 200);   // test core pushes one byte per two clocks
    bfm.reg_read(`FW2_REG_FIFO_STAT, d);
    check_eq(d, 8'h96, "RX full + overrun");
    bfm.reg_write(7'h25, 8'h00);
    bfm.burst_read(`FW2_REG_FIFO_CNT0, 2);
    check_eq(bfm.rx_buf[0], 8'h00, "RX count = 4096 lo");
    check_eq(bfm.rx_buf[1], 8'h10, "RX count = 4096 hi");
    bfm.reg_write(`FW2_REG_FIFO_CTRL, 8'h05);        // flush rx + clear flags
    bfm.reg_read(`FW2_REG_FIFO_STAT, d);
    check_eq(d, 8'h85, "RX flushed");
    // host -> FPGA burst on 0x60 (hold-address)
    for (i = 0; i < 100; i = i + 1) bfm.tx_buf[i] = 8'h10 + i[7:0];
    bfm.burst_write(`FW2_REG_FIFO_TX, 100);
    #(400*CLK_HALF_NS);
    bfm.reg_read(7'h19, d);
    check_eq(d, 8'd100, "user core popped 100 TX bytes");
    bfm.reg_read(7'h18, d);
    check_eq(d, 8'h10 + 8'd99, "last TX byte is the 100th");
    $display("  stream FIFO ok (1000 B pattern, hold-address bursts, flags, 100 B TX)");
  end else begin
    bfm.reg_read(`FW2_REG_FIFO_STAT, d);
    check_eq(d, 8'h00, "no stream capability: status reads 0");
    $display("  stream FIFO not built (capability clear), status reads 0");
  end

  // ---- 5b. arm
  bfm.reg_write(`FW2_REG_IO_ARM, 8'h01);
  bfm.reg_read(`FW2_REG_IO_ARM, d);
  check_eq(d, 8'h01, "IO_ARM reads back 1");
  // inside the window the SPI inner nets still belong to the bus
  bfm.release_bus;
  #(6*CLK_HALF_NS);
  check(rp_pad[`FW2_SIG_SPI_MISO] !== 1'bz, "MISO_Rp drives inside window when armed");
  check(rp_pad[`FW2_SIG_SPI_CS] === 1'bz && rp_pad[`FW2_SIG_SPI_SCLK] === 1'bz && rp_pad[`FW2_SIG_SPI_MOSI] === 1'bz,
        "SPI CS/SCLK/MOSI inner nets released inside window");
  for (i = 0; i < 4; i = i + 1)
    if (mode_of(i) == `FW2_MODE_PASS_OUT)
      check(hdr_pad[i] === 1'bz, "PASS_OUT SPI header pad released inside window (stock behaviour)");
  bfm.io_config_en(1'b0);
  #(6*CLK_HALF_NS);
  check_armed_drivers(10'h3FF);
  check_armed_drivers(10'h000);
  check_armed_drivers(10'b1010101010);
  // inputs reach the user core: FPGA_IN / LINK_RP2F levels readable
  tb_hdr_oe = 10'd0; tb_rp_oe = 10'd0;
  for (i = 0; i < 10; i = i + 1) begin
    if (mode_of(i) == `FW2_MODE_FPGA_IN)   begin tb_hdr_oe[i] = 1'b1; tb_hdr_val[i] = 1'b1; end
    if (mode_of(i) == `FW2_MODE_LINK_RP2F) begin tb_rp_oe[i]  = 1'b1; tb_rp_val[i]  = 1'b1; end
  end
  bfm.io_config_en(1'b1);
  bfm.burst_read(7'h1A, 4);
  for (i = 4; i < 10; i = i + 1) begin   // skip the SPI nets, which the bus owns in the window
    if (mode_of(i) == `FW2_MODE_FPGA_IN)
      check({bfm.rx_buf[1], bfm.rx_buf[0]} >> i & 1, "FPGA_IN level visible on hdr_in");
    if (mode_of(i) == `FW2_MODE_LINK_RP2F)
      check({bfm.rx_buf[3], bfm.rx_buf[2]} >> i & 1, "LINK_RP2F level visible on rp_in");
  end
  tb_hdr_oe = 10'd0; tb_rp_oe = 10'd0;
  // user value 0 reaches FPGA_OUT pads (UART/GPIO pads keep driving inside the window)
  bfm.reg_write(7'h1E, 8'h00);
  bfm.reg_write(7'h1F, 8'h00);
  #(4*CLK_HALF_NS);
  for (i = 4; i < 10; i = i + 1)
    if (mode_of(i) == `FW2_MODE_FPGA_OUT) check(hdr_pad[i] === 1'b0, "FPGA_OUT pad follows hdr_out = 0");
  bfm.reg_write(7'h1E, 8'hFF);
  bfm.reg_write(7'h1F, 8'h03);
  $display("  armed drivers ok: exactly the profile's outputs drive");

  // ---- 5c. reset disarms and sets the sticky flag
  bfm.reg_write(`FW2_REG_RESET, 8'h01);
  bfm.release_bus;
  bfm.io_config_en(1'b0);
  #(6*CLK_HALF_NS);
  check_all_z("disarmed after register 0x01 reset");
  bfm.io_config_en(1'b1);
  bfm.reg_read(`FW2_REG_IO_ARM, d);
  check_eq(d, 8'h02, "0x0F = sticky reset-since-arm, arm clear");
  bfm.reg_read(7'h13, d);
  check_eq(d, 8'h00, "user core was reset by register 0x01");
  bfm.reg_write(`FW2_REG_IO_ARM, 8'h01);
  bfm.reg_read(`FW2_REG_IO_ARM, d);
  check_eq(d, 8'h01, "re-arm clears the sticky flag");
  bfm.io_config_en(1'b0);
  bfm.release_bus;
  #(6*CLK_HALF_NS);
  check_armed_drivers(10'h3FF);
  // ---- 5d. IO_ARM=0 releases without a reset
  bfm.io_config_en(1'b1);
  bfm.reg_write(`FW2_REG_IO_ARM, 8'h00);
  bfm.io_config_en(1'b0);
  bfm.release_bus;
  #(6*CLK_HALF_NS);
  check_all_z("disarmed by IO_ARM=0");
  bfm.io_config_en(1'b1);
  bfm.reg_read(`FW2_REG_IO_ARM, d);
  check_eq(d, 8'h00, "0x0F = 0 after IO_ARM=0 (no reset happened)");
  // a reset while disarmed does not set the sticky flag
  bfm.reg_write(`FW2_REG_RESET, 8'h01);
  bfm.reg_read(`FW2_REG_IO_ARM, d);
  check_eq(d, 8'h00, "reset while disarmed leaves the sticky flag clear");
  $display("  arm / reset / sticky flag ok");

  // ---- 7. pad-readback contention flags (0x0D/0x0E)
  // State here: disarmed, user core reset (drives 1 on every FPGA_OUT pad once
  // armed), window open. The tb profile has UART_TX (sig 4 -> 0x0E bit 4) and
  // GPIO26 (sig 8 -> 0x0D bit 0) in FPGA_OUT, one per byte.
  check(mode_of(`FW2_SIG_UART_TX) == `FW2_MODE_FPGA_OUT && mode_of(`FW2_SIG_GPIO26) == `FW2_MODE_FPGA_OUT,
        "tb_design profile must keep UART_TX and GPIO26 in FPGA_OUT (section 7 relies on it)");
  // (e) reads while disarmed are 0; a fought pad is not driven, so nothing is set
  bfm.reg_read(`FW2_REG_CONTENTION, d);
  check_eq(d, 8'h00, "0x0E reads 0 while disarmed");
  bfm.reg_read(`FW2_REG_CONTENTION_GPIO, d);
  check_eq(d, 8'h00, "0x0D reads 0 while disarmed");
  bfm.io_config_en(1'b0);
  bfm.release_bus;
  fight(`FW2_SIG_UART_TX, 1'b0, 10);
  fight(`FW2_SIG_GPIO26, 1'b0, 10);
  read_contention(d, d2);
  check_eq(d,  8'h00, "0x0E stays 0: a fight while disarmed is not contention");
  check_eq(d2, 8'h00, "0x0D stays 0: a fight while disarmed is not contention");
  // arm; nothing fought yet
  bfm.io_config_en(1'b1);
  bfm.reg_write(`FW2_REG_IO_ARM, 8'h01);
  bfm.io_config_en(1'b0);
  bfm.release_bus;
  #(6*CLK_HALF_NS);
  check(hdr_pad[`FW2_SIG_UART_TX] === 1'b1 && hdr_pad[`FW2_SIG_GPIO26] === 1'b1, "FPGA_OUT pads drive 1 before any fight");
  read_contention(d, d2);
  check_eq(d,  8'h00, "0x0E = 0 after arm, nothing fought");
  check_eq(d2, 8'h00, "0x0D = 0 after arm, nothing fought");
  // (a) 10-clock fights: bit set, read returns it, the read clears only that byte
  fight(`FW2_SIG_UART_TX, 1'b0, 10);
  check(hdr_pad[`FW2_SIG_UART_TX] === 1'b1, "pad is back at the FPGA level after the fight");
  fight(`FW2_SIG_GPIO26, 1'b0, 10);
  bfm.io_config_en(1'b1);
  bfm.reg_read(`FW2_REG_CONTENTION, d);
  check_eq(d, 8'h10, "0x0E bit 4 set: UART_TX pad fought low for 10 clocks");
  bfm.reg_read(`FW2_REG_CONTENTION, d);
  check_eq(d, 8'h00, "0x0E cleared by its own read");
  bfm.reg_read(`FW2_REG_CONTENTION_GPIO, d);
  check_eq(d, 8'h01, "0x0D bit 0 set (GPIO26), untouched by the 0x0E read");
  bfm.reg_read(`FW2_REG_CONTENTION_GPIO, d);
  check_eq(d, 8'h00, "0x0D cleared by its own read");
  bfm.reg_read(`FW2_REG_CONTENTION, d);
  check_eq(d, 8'h00, "0x0E still 0 after the 0x0D read");
  bfm.io_config_en(1'b0);
  bfm.release_bus;
  // a 2-byte burst from 0x0D reads and clears both
  fight(`FW2_SIG_UART_TX, 1'b0, 10);
  fight(`FW2_SIG_GPIO26, 1'b0, 10);
  bfm.io_config_en(1'b1);
  bfm.burst_read(`FW2_REG_CONTENTION_GPIO, 2);
  check_eq(bfm.rx_buf[0], 8'h01, "burst byte 0 = 0x0D");
  check_eq(bfm.rx_buf[1], 8'h10, "burst byte 1 = 0x0E");
  bfm.burst_read(`FW2_REG_CONTENTION_GPIO, 2);
  check_eq(bfm.rx_buf[0], 8'h00, "burst cleared 0x0D");
  check_eq(bfm.rx_buf[1], 8'h00, "burst cleared 0x0E");
  bfm.io_config_en(1'b0);
  bfm.release_bus;
  // agreement is not contention, either polarity; disagreement is, either polarity
  fight(`FW2_SIG_UART_TX, 1'b1, 10);
  read_contention(d, d2);
  check_eq(d, 8'h00, "a device driving the same level (1) sets nothing");
  bfm.io_config_en(1'b1);
  bfm.reg_write(7'h1E, 8'h00);             // user core now drives 0
  bfm.io_config_en(1'b0);
  bfm.release_bus;
  #(4*CLK_HALF_NS);
  check(hdr_pad[`FW2_SIG_UART_TX] === 1'b0, "UART_TX pad follows hdr_out = 0");
  fight(`FW2_SIG_UART_TX, 1'b0, 10);
  read_contention(d, d2);
  check_eq(d, 8'h00, "a device driving the same level (0) sets nothing");
  fight(`FW2_SIG_UART_TX, 1'b1, 10);
  read_contention(d, d2);
  check_eq(d, 8'h10, "fought high while the core drives 0: bit set");
  bfm.io_config_en(1'b1);
  bfm.reg_write(7'h1E, 8'hFF);
  bfm.io_config_en(1'b0);
  bfm.release_bus;
  #(4*CLK_HALF_NS);
  // (b) the 4-clock filter: 2 and 3 clocks do not set, 4 does, two 2s do not add up
  fight(`FW2_SIG_UART_TX, 1'b0, 2);
  read_contention(d, d2);
  check_eq(d, 8'h00, "2-clock disagreement is filtered");
  fight(`FW2_SIG_UART_TX, 1'b0, 3);
  read_contention(d, d2);
  check_eq(d, 8'h00, "3-clock disagreement is filtered");
  fight(`FW2_SIG_UART_TX, 1'b0, 4);
  read_contention(d, d2);
  check_eq(d, 8'h10, "4 consecutive clocks set the bit");
  fight(`FW2_SIG_UART_TX, 1'b0, 2);
  fight(`FW2_SIG_UART_TX, 1'b0, 2);
  read_contention(d, d2);
  check_eq(d, 8'h00, "two separate 2-clock disagreements do not accumulate");
  // (c) PASS_OUT / PASS_IN / FPGA_IN / LINK_* / OFF signals never set a bit
  fight_non_fpga_out(1'b0, 10);
  read_contention(d, d2);
  check_eq(d,  8'h00, "0x0E: non-FPGA_OUT signals fought low set nothing");
  check_eq(d2, 8'h00, "0x0D: non-FPGA_OUT signals fought low set nothing");
  fight_non_fpga_out(1'b1, 10);
  read_contention(d, d2);
  check_eq(d,  8'h00, "0x0E: non-FPGA_OUT signals fought high set nothing");
  check_eq(d2, 8'h00, "0x0D: non-FPGA_OUT signals fought high set nothing");
  // (d) a pending flag is cleared by disarm, and by reg 0x01
  fight(`FW2_SIG_UART_TX, 1'b0, 10);
  fight(`FW2_SIG_GPIO26, 1'b0, 10);
  bfm.io_config_en(1'b1);
  bfm.reg_write(`FW2_REG_IO_ARM, 8'h00);
  bfm.reg_read(`FW2_REG_CONTENTION, d);
  check_eq(d, 8'h00, "disarm clears 0x0E");
  bfm.reg_read(`FW2_REG_CONTENTION_GPIO, d);
  check_eq(d, 8'h00, "disarm clears 0x0D");
  bfm.reg_write(`FW2_REG_IO_ARM, 8'h01);
  bfm.reg_read(`FW2_REG_CONTENTION, d);
  check_eq(d, 8'h00, "nothing pending after re-arm");
  bfm.io_config_en(1'b0);
  bfm.release_bus;
  #(4*CLK_HALF_NS);
  fight(`FW2_SIG_UART_TX, 1'b0, 10);
  bfm.io_config_en(1'b1);
  bfm.reg_write(`FW2_REG_RESET, 8'h01);
  bfm.reg_read(`FW2_REG_CONTENTION, d);
  check_eq(d, 8'h00, "reg 0x01 reset clears 0x0E");
  bfm.reg_read(`FW2_REG_IO_ARM, d);
  check_eq(d, 8'h02, "and disarmed with the sticky flag, as before");
  // writes to 0x0D/0x0E are ignored (no way to set a bit from the bus)
  bfm.reg_write(`FW2_REG_IO_ARM, 8'h01);
  bfm.tx_buf[0] = 8'hFF; bfm.tx_buf[1] = 8'hFF;
  bfm.burst_write(`FW2_REG_CONTENTION_GPIO, 2);
  bfm.burst_read(`FW2_REG_CONTENTION_GPIO, 2);
  check_eq(bfm.rx_buf[0], 8'h00, "write to 0x0D ignored");
  check_eq(bfm.rx_buf[1], 8'h00, "write to 0x0E ignored");
  bfm.reg_write(`FW2_REG_IO_ARM, 8'h00);
  $display("  contention flags ok: 0x0E bit 4 / 0x0D bit 0, 4-clock filter, clear on read / disarm / reset");

  $display("tb_shell PASS: %0d checks, %0d errors", checks, errors);
  $finish;
end

// watchdog
initial begin
  #(200_000_000);
  $fatal(1, "tb_shell: timeout");
end

endmodule
