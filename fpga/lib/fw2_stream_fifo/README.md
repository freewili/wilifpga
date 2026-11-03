# fw2_stream_fifo

New code (FreeWili 2 FPGA BSP). Register-bus stream FIFO behind the shell's 0x60-0x6F window: a 4096-byte EBR FIFO for FPGA -> host data (read at 0x61 with hold-address bursts) and a 256-byte EBR FIFO for host -> FPGA data (written at 0x60). Status 0x62 (levels + sticky overrun/underrun flags, cleared when 0x62 has been read or by control bit 2), control 0x63 (flush RX/TX, clear flags), RX byte count 0x64-0x67 little endian. Built into `fw2_shell` only when the design's capabilities include `STREAM`. `fw2_fifo_sync.v` is the generic synchronous FIFO it uses (one-clock pop-to-next-byte latency).

**Ports:** `clk, rst`; host side `host_addr[3:0], host_rdata, host_wr, host_wdata, host_rd_done, host_rd_addr[3:0]`; user side `fifo_tx_data/valid/ready` (host -> FPGA), `fifo_rx_data/valid/ready` (FPGA -> host). Parameters `RX_AW` (12), `TX_AW` (8).

**Status:** new, simulated in `fpga/sim/tb_shell.v` (1000-byte pattern burst, partial drain, underrun, overrun, flush, 100-byte TX burst); unverified on hardware. Driver notes: `docs/drivers/stream_fifo.md`.
