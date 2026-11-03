# logic_capture

An 8-channel logic sampler (T1 data path): the eight shifter-driven header
signals as `FPGA_IN`, sampled at 31.25 MS/s divided by (0x10 + 1), one byte per
sample pushed into the shell's stream FIFO (register 0x61), GPIO26 as the
trigger input. Capabilities `IO_BUFFER` + `STREAM`.

## What you learn

The stream FIFO and its registers (0x60-0x67), hold-address burst reads, the
same-cycle `fifo_rx_valid`/`fifo_rx_ready` handshake (a sample is held until
the FIFO takes it), one-shot vs continuous capture, a trigger with edge
selection, and the T1 throughput ceiling of the register bus.

## Build & load

```sh
tools/fwfpga build logic_capture
tools/fwfpga sim logic_capture
tools/fwfpga install logic_capture
tools/fwfpga load logic_capture
```

The testbench checks divider timing (100 samples in 800 clocks at div 7), sample ordering,
one-shot completion with exactly 64 accepted samples when a 64-entry FIFO
model fills (none lost, none extra), rising / falling trigger, and the dropped
flag. The FIFO itself is covered by `fpga/sim/tb_shell.v`.

## Verify

`fwfpga reg w 0x10 0xFF` (122 kS/s), `fwfpga reg w 0x11 0x03` (one-shot):
4096 samples take 33.6 ms, then 0x13 reads `0x05` (done, not running) and
0x64..0x67 read `00 10 00 00` (4096). `fwfpga stream rx 4096` (firmware
`h\f\x`, 256 bytes per call in v1) drains it; bit 0 of every byte is SPI MISO
(GPIO12) ... bit 7 UART RTS (GPIO11). Toggle a header pin (a switch or jumper to
ground) during a capture and find the edge in the dump. Trigger test:
`0x12 = 0x01`, `0x11 = 0x07`, then raise GPIO26; 0x13 bit 1 sets and the FIFO
fills from that edge. Throughput: at 3.25 MHz SCK the host drains about 400
KB/s (`docs/drivers/stream_fifo.md`), so continuous mode at div >= 77 (~400
kS/s) runs without `dropped`.

## Pins used

| signal | index | mode | role |
|---|---|---|---|
| SPI MISO/CS/SCLK/MOSI | 0-3 | `FPGA_IN` | sample bits 0-3 |
| UART TX/RX/CTS/RTS | 4-7 | `FPGA_IN` | sample bits 4-7 |
| GPIO26 | 8 | `FPGA_IN` | trigger |
| GPIO27 | 9 | `PASS_OUT` | stock passthrough |

While armed the RP2350 has GPIO 8-15 as inputs (firmware profile engine); the
register bus still reaches the shell through the SPI1 inner nets inside the
IO_CONFIG_ENABLE window.

## Registers

| addr | R/W | contents |
|---|---|---|
| 0x10 | RW | sample divider: one sample every (value + 1) clocks (0 = 31.25 MS/s, 0xFF = 122 kS/s) |
| 0x11 | RW | control: bit 0 run, bit 1 one-shot (stop and set done when the FIFO is full), bit 2 wait for trigger. Writing restarts the capture and clears the status bits; bit 0 self-clears when a one-shot completes |
| 0x12 | RW | trigger: 0 none, 1 rising edge on GPIO26, 2 falling, 3 either |
| 0x13 | R | status: bit 0 running, bit 1 triggered/capturing, bit 2 done, bit 3 dropped (continuous mode, FIFO was full) |
| 0x14 | R | live input byte |
| 0x60-0x67 | shell | stream FIFO: read samples at 0x61 (hold-address burst), count at 0x64-0x67, status 0x62 |
