# `design.toml` and the `.fwfpga` container

A bitstream never travels without its IO metadata. The firmware and the CLI
accept exactly one file type: a `.fwfpga` container
whose fixed 256-byte header carries the design's identity and IO profile,
followed by an optional host-only JSON manifest and the iCE40 bitstream. Both
the header and the fabric's ID block are generated from the same `design.toml`
by `fwfpga build`, and the firmware compares them after CDONE.

Single source of the layout: `tools/fwfpga_format.py` (`FIELDS`). It renders
`firmware/generated/fw2_fwfpga_format.h` via `tools/gen_fwfpga_format_h.py`;
`tools/tests/test_fwfpga_format_c.py` fails when that header is stale and
compiles it with host gcc against Python-packed bytes.

## `design.toml`

```toml
[design]
name = "hello_blink"          # <= 31 printable ASCII; letters, digits, _ . -; must equal the folder name
description = "Blink GPIO26 from the fabric; first bitfile tutorial."   # <= 127 ASCII, required, no default
version = "001"               # exactly three digits, hand-bumped
design_id = 1                 # u16, unique across designs/*; 0xFFFF is reserved for kind = "stock"
kind = "user"                 # "user" | "stock" (default "user")
clock_hz = 31250000           # 31250000 (code 0, stock) | 12500000 (1) | 25000000 (2) | 48000000 (3)
capabilities = ["IO_BUFFER", "STREAM"]   # IO_BUFFER=1 STREAM=2 I2C_SLAVE=16; [] allowed (4, 8: stock gateware only)
repository = "https://github.com/freewili/wilifpga"

[io_profile]                  # all ten signals required; values are mode names
spi_miso = "PASS_IN"
spi_cs   = "PASS_OUT"
spi_sclk = "PASS_OUT"
spi_mosi = "PASS_OUT"
uart_tx  = "PASS_OUT"
uart_rx  = "PASS_IN"
uart_cts = "PASS_IN"
uart_rts = "PASS_OUT"
gpio26   = "FPGA_OUT"
gpio27   = "PASS_OUT"

[registers]                   # optional, free form; copied into the container manifest
0x10 = "blink period, 8 bit"
```

Optional build hints in `[design]`, used only by `fwfpga build`/`lint`/`sim`:
`top = "main"` overrides the kind default (`fw2_shell` for user designs,
`main` for stock); `sources = ["my_top.v", "my_core.v"]` names the design's
own Verilog files (relative to the folder, globs allowed) instead of every
`*.v` in it; `include_dirs = ["fpga/lib/fw2_stream_fifo"]` adds repo-relative
`-I` directories. `fpga/shell`, the build directory (for the generated
`fw2_design_id.vh`) and every `fpga/lib/<module>/` folder that contains a
`.vh` are always on the include path. A user design is compiled with
`fpga/shell/*.v` + `fpga/lib/**/*.v` + its own sources; a stock design with
`fpga/lib/**/*.v` minus the `fw2_*` modules + its own sources (unused modules
are dropped by `synth_ice40 -top`).

Rules enforced by `tools/design_toml.py` (used by every tool): every key in
`[design]` above except `kind` is required; unknown keys or tables other than
`[registers]`/`[host]` are errors; `kind = "stock"` requires
`design_id = 65535` and vice versa; capability names must be from the list and
appear once. `tools/check_design.py` adds the folder-name rule, `design_id`
uniqueness, and contract rules 1 and 4 (no pad name from `fw2.pcf` in any
`*.v`/`*.vh`/`*.sv` directly in the design folder; `tb/` and `host/` are not
scanned; a user design declares `module user_core` and never `fw2_shell` or
`main`; stock designs are exempt from the pad rule).

### IO profile encoding (`tools/profile.py`)

Signal order is the bit order; signal *i* occupies bits `[3i+2:3i]` of a
little-endian u32. Bits 30 and 31 are zero; mode code 7 is invalid.

| i | signal | RP2350 GPIO |  | code | mode |
|---|---|---|---|---|---|
| 0 | spi_miso | 12 |  | 0 | `PASS_OUT` |
| 1 | spi_cs | 13 |  | 1 | `PASS_IN` |
| 2 | spi_sclk | 14 |  | 2 | `FPGA_OUT` |
| 3 | spi_mosi | 15 |  | 3 | `FPGA_IN` |
| 4 | uart_tx | 8 |  | 4 | `LINK_RP2F` |
| 5 | uart_rx | 9 |  | 5 | `LINK_F2RP` |
| 6 | uart_cts | 10 |  | 6 | `OFF` |
| 7 | uart_rts | 11 |  | 7 | invalid |
| 8 | gpio26 | 26 |  |  |  |
| 9 | gpio27 | 27 |  |  |  |

Per-mode settings, which the firmware and the shell both apply:

| mode | RP2350 pin | FPGA `_Rp` | FPGA `_Out` | shifter DIR |
|---|---|---|---|---|
| `PASS_OUT` | out | in | out | to header |
| `PASS_IN` | in | out | in | to board |
| `FPGA_OUT` | in, no pull | Z | out | to header |
| `FPGA_IN` | in, no pull | Z | in | to board |
| `LINK_RP2F` | out | in | Z | to board |
| `LINK_F2RP` | in | out | Z | to board |
| `OFF` | in | Z | Z | to board |

The stock profile (`spi_miso`, `uart_rx`, `uart_cts`, `gpio26` = `PASS_IN`,
the rest `PASS_OUT`) packs to `0x01048001`. The one-line summary shown by
panels and `fwfpga inspect` lists FPGA_OUT signals as `drives:` and FPGA_IN as
`reads:` (`drives: SPI1 CS, UART1 TX; reads: GPIO26`); LINK and OFF get their
own groups; an all-PASS profile reads `stock passthrough`.

## The ID block (`tools/gen_design_id.py`)

Sixteen read-only bytes at register `0x70` of every `fw2_shell` design,
generated into `fw2_design_id.vh`:

| register | bytes | field |
|---|---|---|
| 0x70..0x73 | 4 | `"FW2F"` = 46 57 32 46 |
| 0x74 | 1 | contract_version = 1 |
| 0x75..0x76 | 2 | design_id, LE |
| 0x77..0x78 | 2 | design_version, LE (0..999) |
| 0x79 | 1 | capabilities |
| 0x7A | 1 | clock_code |
| 0x7B..0x7E | 4 | io_profile, LE |
| 0x7F | 1 | checksum = XOR of bytes 0x70..0x7E |

`fw2_design_id.vh` defines `FW2_DESIGN_ID 16'd<id>`, `FW2_DESIGN_VERSION
16'd<n>`, `FW2_DESIGN_CAPS 8'h<xx>`, `FW2_DESIGN_CLOCK_CODE 8'd<c>`,
`FW2_DESIGN_CLOCK_HZ <hz>`, `FW2_DESIGN_IO_PROFILE 32'h<xxxxxxxx>`,
`FW2_DESIGN_CHECKSUM 8'h<xx>`, `FW2_DESIGN_CONTRACT_VERSION 8'd1` and one
`FW2_IOP_<SIGNAL> 3'd<mode>` per signal, inside an `FW2_DESIGN_ID_VH` guard.

## The container header (`tools/fwfpga_format.py`)

Little-endian; CRC-32 is zlib's (polynomial 0xEDB88320 reflected, init and
final XOR 0xFFFFFFFF).

| offset | size | field | notes |
|---|---|---|---|
| 0 | 8 | magic | `"FW2FPGA\0"` |
| 8 | 1 | format_version | 1; unknown values are rejected, never guessed |
| 9 | 1 | contract_version | 1; the ID block contract the design was built to |
| 10 | 2 | header_len | 256 |
| 12 | 4 | manifest_len | JSON blob length, may be 0 |
| 16 | 4 | bitstream_len | |
| 20 | 4 | bitstream_crc32 | zlib CRC-32 of the bitstream |
| 24 | 32 | bitstream_sha256 | |
| 56 | 32 | name | ASCII, NUL padded, <= 31 chars |
| 88 | 128 | description | ASCII, NUL padded, <= 127 chars |
| 216 | 2 | design_id | 0xFFFF = stock gateware, no ID block expected |
| 218 | 2 | design_version | 0..999 |
| 220 | 1 | capabilities | bit field, see above |
| 221 | 1 | clock_code | 0..3 |
| 222 | 4 | io_profile | same encoding as the ID block |
| 226 | 1 | kind | 0 = user design, 1 = stock passthrough |
| 227 | 25 | reserved | zero |
| 252 | 4 | header_crc32 | zlib CRC-32 over bytes 0..251 |
| 256 | manifest_len | manifest | host-only JSON |
| ... | bitstream_len | bitstream | iCE40 image; `7E AA 99 7E` within its first 64 bytes |

The file length must equal `256 + manifest_len + bitstream_len` exactly.

### Manifest

`pack_fwfpga.py` writes `{"format": "fwfpga-manifest/1", "packer": ...,
"built": <ISO-8601 UTC, honours SOURCE_DATE_EPOCH>, "repository": ...,
"design": <design.toml echo incl. [registers]>, "tools": {yosys, nextpnr-ice40,
icepack versions}}`; `fwfpga build` adds `"build": {freq_mhz, fmax,
utilization, top}`. The firmware skips the manifest by length and never parses
it. `--no-manifest` writes none.

### Checks (`tools/check_container.py`, contract rule 8)

Run after `fwfpga build` and before `fwfpga install`: magic, known
`format_version`, header CRC, exact file length, bitstream CRC-32 and SHA-256,
contract version, kind in {0, 1}, stock <-> 0xFFFF rule, version <= 999,
reserved bytes zero, non-empty name and description, decodable profile (no
code 7, bits 30/31 clear), known capability bits and clock code, iCE40
preamble, bitstream size 100 KB..1 MB (`--allow-size` for tests), manifest is
JSON, and -- given `--design` or a matching `designs/<name>/design.toml` --
name, description, design_id, version, capabilities, clock_code, io_profile,
kind and contract_version all equal the `design.toml`. Each check is a test in
`tools/tests/test_fwfpga_format.py` and
`tools/tests/test_pack_and_check_container.py`, including every single-byte
header corruption and a bitstream flip with the CRC patched (caught by SHA-256).

### The generated C header

`firmware/generated/fw2_fwfpga_format.h` provides the packed
`fw2_fwfpga_header_t` with `_Static_assert`s on size and every offset, the
`fw2_fwfpga_kind_t`, `fw2_fwfpga_cap_t`, `fw2_clock_code_t`, `fw2_iop_mode_t`
and `fw2_iop_signal_t` enums, `FW2_IOP_MODE(packed, sig)`, the ID block
offsets, `fw2_crc32_update()` (table driven, zlib compatible),
`fw2_fwfpga_header_valid(raw256, crc32_fn_or_NULL)` for the pre-CRESET gate,
`fw2_fwfpga_header_parse()` (endian safe), `fw2_fwfpga_header_check_fields()`,
`fw2_ice40_has_preamble()`, `fw2_idblk_from_header()` and
`fw2_idblk_compare()`, which returns the first disagreeing field so the
firmware can name it when it restores stock. Copy the file into the firmware
tree unchanged; regenerate with `py -3 tools/gen_fwfpga_format_h.py` and verify
with `--check`.
