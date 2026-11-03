#!/usr/bin/env python3
"""The FreeWili 2 FPGA IO profile: ten header signals, one 3-bit mode each.

    python tools/profile.py summary 0x12492489      # decode a packed profile
    python tools/profile.py table                   # the per-mode derived table

This is the single source for the IO direction model (docs/fwfpga-format.md). The
same encoding appears in three places that must agree byte for byte:

- `fw2_design_id.vh` (gen_design_id.py) -> the ID block at register 0x7B..0x7E
- the `.fwfpga` container header, offset 222 (fwfpga_format.py)
- the firmware's profile engine (ported from the tables below)

Packed form: u32 little-endian, signal i (0..9) occupies bits [3i+2:3i].
Bits 30 and 31 are zero. Mode code 7 is invalid.
"""
import sys

# Signal order is the bit order. Index 0 is bits [2:0].
SIGNALS = (
    ("spi_miso", "SPI1 MISO", 12),
    ("spi_cs", "SPI1 CS", 13),
    ("spi_sclk", "SPI1 SCLK", 14),
    ("spi_mosi", "SPI1 MOSI", 15),
    ("uart_tx", "UART1 TX", 8),
    ("uart_rx", "UART1 RX", 9),
    ("uart_cts", "UART1 CTS", 10),
    ("uart_rts", "UART1 RTS", 11),
    ("gpio26", "GPIO26", 26),
    ("gpio27", "GPIO27", 27),
)
SIGNAL_NAMES = tuple(s[0] for s in SIGNALS)
SIGNAL_LABELS = {s[0]: s[1] for s in SIGNALS}
SIGNAL_RP_GPIO = {s[0]: s[2] for s in SIGNALS}

MODES = {
    "PASS_OUT": 0,
    "PASS_IN": 1,
    "FPGA_OUT": 2,
    "FPGA_IN": 3,
    "LINK_RP2F": 4,
    "LINK_F2RP": 5,
    "OFF": 6,
}
MODE_NAMES = {v: k for k, v in MODES.items()}
MODE_BITS = 3
PROFILE_MASK = (1 << (MODE_BITS * len(SIGNALS))) - 1   # 0x3FFFFFFF

# Derived settings per mode (docs/fwfpga-format.md). Values are deliberately short tokens so
# the firmware port and the Verilog generator can map them 1:1.
#   rp_dir       RP2350 pin:      out | in | in_nopull
#   fpga_rp_dir  FPGA `_Rp` pad:  in | out | z
#   fpga_out_dir FPGA `_Out` pad: in | out | z
#   shifter_dir  level-shifter DIR: to_header | to_board
MODE_TABLE = {
    "PASS_OUT":  {"rp_dir": "out",       "fpga_rp_dir": "in",  "fpga_out_dir": "out", "shifter_dir": "to_header",
                  "use": "stock behaviour, RP peripheral drives header"},
    "PASS_IN":   {"rp_dir": "in",        "fpga_rp_dir": "out", "fpga_out_dir": "in",  "shifter_dir": "to_board",
                  "use": "stock behaviour, header drives RP peripheral"},
    "FPGA_OUT":  {"rp_dir": "in_nopull", "fpga_rp_dir": "z",   "fpga_out_dir": "out", "shifter_dir": "to_header",
                  "use": "FPGA drives the header pin"},
    "FPGA_IN":   {"rp_dir": "in_nopull", "fpga_rp_dir": "z",   "fpga_out_dir": "in",  "shifter_dir": "to_board",
                  "use": "header drives the FPGA"},
    "LINK_RP2F": {"rp_dir": "out",       "fpga_rp_dir": "in",  "fpga_out_dir": "z",   "shifter_dir": "to_board",
                  "use": "fast inner-net link, RP -> FPGA (header isolated)"},
    "LINK_F2RP": {"rp_dir": "in",        "fpga_rp_dir": "out", "fpga_out_dir": "z",   "shifter_dir": "to_board",
                  "use": "fast inner-net link, FPGA -> RP"},
    "OFF":       {"rp_dir": "in",        "fpga_rp_dir": "z",   "fpga_out_dir": "z",   "shifter_dir": "to_board",
                  "use": "unused"},
}

# The stock gateware's behaviour: SPI1 master + UART1 on the RP2350, GPIO26 in, GPIO27 out.
STOCK_PROFILE = {
    "spi_miso": "PASS_IN",
    "spi_cs": "PASS_OUT",
    "spi_sclk": "PASS_OUT",
    "spi_mosi": "PASS_OUT",
    "uart_tx": "PASS_OUT",
    "uart_rx": "PASS_IN",
    "uart_cts": "PASS_IN",
    "uart_rts": "PASS_OUT",
    "gpio26": "PASS_IN",
    "gpio27": "PASS_OUT",
}


class ProfileError(ValueError):
    pass


def validate(profile):
    """Raise ProfileError unless `profile` maps exactly the ten signals to mode names."""
    if not isinstance(profile, dict):
        raise ProfileError("io_profile must be a table of signal = \"MODE\"")
    missing = [s for s in SIGNAL_NAMES if s not in profile]
    extra = [s for s in profile if s not in SIGNAL_NAMES]
    if missing:
        raise ProfileError("io_profile is missing: " + ", ".join(missing))
    if extra:
        raise ProfileError("io_profile has unknown signals: " + ", ".join(sorted(extra)))
    for sig in SIGNAL_NAMES:
        mode = profile[sig]
        if mode not in MODES:
            raise ProfileError(f"io_profile.{sig} = {mode!r} is not one of {', '.join(MODES)}")
    return profile


def pack(profile):
    """Ten mode names -> packed u32."""
    validate(profile)
    value = 0
    for i, sig in enumerate(SIGNAL_NAMES):
        value |= MODES[profile[sig]] << (MODE_BITS * i)
    return value


def unpack(value):
    """Packed u32 -> {signal: mode name}. Rejects code 7 and non-zero bits 30/31."""
    if not 0 <= value <= 0xFFFFFFFF:
        raise ProfileError(f"io_profile {value!r} is not a u32")
    if value & ~PROFILE_MASK:
        raise ProfileError(f"io_profile 0x{value:08X} has bits 30/31 set")
    out = {}
    for i, sig in enumerate(SIGNAL_NAMES):
        code = (value >> (MODE_BITS * i)) & 0x7
        if code not in MODE_NAMES:
            raise ProfileError(f"io_profile 0x{value:08X}: signal {sig} has invalid mode code {code}")
        out[sig] = MODE_NAMES[code]
    return out


def codes(profile):
    """[mode code per signal], index order."""
    validate(profile)
    return [MODES[profile[s]] for s in SIGNAL_NAMES]


def derived(profile):
    """{signal: {mode, rp_dir, fpga_rp_dir, fpga_out_dir, shifter_dir}}."""
    validate(profile)
    return {s: dict(mode=profile[s], **{k: v for k, v in MODE_TABLE[profile[s]].items() if k != "use"})
            for s in SIGNAL_NAMES}


def summary(profile):
    """One line for panels and the CLI: what the FPGA does to the header.

    'drives: SPI1 CS, UART1 TX; reads: GPIO26'. LINK and OFF signals get their
    own groups; PASS_* signals are the stock behaviour and are not listed, so an
    all-passthrough profile reads 'stock passthrough'.
    """
    validate(profile)
    groups = [("drives", ("FPGA_OUT",)), ("reads", ("FPGA_IN",)),
              ("link", ("LINK_RP2F", "LINK_F2RP")), ("off", ("OFF",))]
    parts = []
    for label, modes in groups:
        names = [SIGNAL_LABELS[s] for s in SIGNAL_NAMES if profile[s] in modes]
        if names:
            parts.append(f"{label}: " + ", ".join(names))
    return "; ".join(parts) if parts else "stock passthrough"


def table_text(profile):
    """Multi-line table: signal, mode, RP pin, _Rp pad, _Out pad, shifter."""
    rows = [("signal", "mode", "RP2350", "FPGA _Rp", "FPGA _Out", "shifter DIR")]
    for sig, d in derived(profile).items():
        rows.append((SIGNAL_LABELS[sig], d["mode"], d["rp_dir"], d["fpga_rp_dir"], d["fpga_out_dir"], d["shifter_dir"]))
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    return "\n".join("  ".join(c.ljust(w) for c, w in zip(r, widths)).rstrip() for r in rows)


def _parse_int(text):
    return int(text, 0)


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("summary", help="decode a packed u32 profile")
    s.add_argument("value", type=_parse_int)
    sub.add_parser("table", help="print the per-mode derived table")
    sub.add_parser("stock", help="print the stock profile, packed and as a table")
    a = p.parse_args(argv)
    if a.cmd == "summary":
        prof = unpack(a.value)
        print(summary(prof))
        print(table_text(prof))
    elif a.cmd == "table":
        for mode, row in MODE_TABLE.items():
            print(f"{mode:<10} code={MODES[mode]}  RP={row['rp_dir']:<9} _Rp={row['fpga_rp_dir']:<3} "
                  f"_Out={row['fpga_out_dir']:<3} DIR={row['shifter_dir']:<9}  {row['use']}")
    elif a.cmd == "stock":
        print(f"0x{pack(STOCK_PROFILE):08X}")
        print(table_text(STOCK_PROFILE))
    return 0


if __name__ == "__main__":
    sys.exit(main())
