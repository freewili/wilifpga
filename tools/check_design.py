#!/usr/bin/env python3
"""Static checks for contract rules 1, 2 and 4 over designs/<name>/.

    python tools/check_design.py designs/hello_blink [--designs-root designs] [--pcf fpga/constraints/fw2.pcf]

- rule 2: design.toml is valid (design_toml.py) and its name is the folder name;
  design_id is unique across designs/*/design.toml.
- rule 1: the top is fw2_shell -- no design file declares `module fw2_shell` or
  `module main`; some design file declares `module user_core`.
- rules 1 and 4: no design file references a pad name from fw2.pcf (so a user
  core cannot drive a `_Rp`/`_Out` pad or a DIR ball). Pad names are read from
  the .pcf when present, else from the known list below.
- kind = "stock" is exempt from the pad and user_core rules (it IS the pads)
  and must have design_id 0xFFFF.

Files scanned: *.v *.vh *.sv *.svh directly in the design folder (not tb/ or
host/: a testbench must name pads to drive the shell).
"""
import re
import sys
from pathlib import Path

import design_toml

REPO_ROOT = Path(__file__).resolve().parents[1]
DESIGNS_ROOT = REPO_ROOT / "designs"
DEFAULT_PCF = REPO_ROOT / "fpga" / "constraints" / "fw2.pcf"

KNOWN_PADS = (
    "SPI_MISO_Rp SPI_MOSI_Rp SPI_Clk_Rp SPI_CS_Rp SPI_MISO_Out SPI_MOSI_Out SPI_Clk_Out SPI_CS_Out "
    "UART_Tx_Rp UART_Rx_Rp UART_CTS_Rp UART_RTS_Rp UART_Tx_Out UART_Rx_Out UART_CTS_Out UART_RTS_Out "
    "GPIO_26_Rp GPIO_27_Rp GPIO_26_Out GPIO_27_Out CLK I2C_SDA I2C_SCL IO_CONFIG_ENABLE "
    "GPIO_26_Dir GPIO_27_Dir SRAM_CLK SRAM_CS SRAM_IO0 SRAM_IO1 SRAM_IO2 SRAM_IO3"
).split()

SOURCE_GLOBS = ("*.v", "*.vh", "*.sv", "*.svh")
FORBIDDEN_TOPS = ("fw2_shell", "main")
USER_TOP = "user_core"

_COMMENT_RE = re.compile(r"//[^\n]*|/\*.*?\*/", re.DOTALL)
_PCF_RE = re.compile(r"^\s*set_io\s+(?:--?\S+\s+)*([A-Za-z_][A-Za-z0-9_$\[\]]*)\s+\S+", re.MULTILINE)
_MODULE_RE = re.compile(r"\bmodule\s+([A-Za-z_][A-Za-z0-9_$]*)")


def pad_names(pcf_path=DEFAULT_PCF):
    """Pad names from a .pcf (set_io NAME PIN), or the known list when the file is absent."""
    pcf_path = Path(pcf_path) if pcf_path else None
    if pcf_path and pcf_path.is_file():
        text = _COMMENT_RE.sub("", pcf_path.read_text(encoding="utf-8", errors="replace").replace("#", "//"))
        names = []
        for m in _PCF_RE.finditer(text):
            n = re.sub(r"\[.*\]$", "", m.group(1))
            if n not in names:
                names.append(n)
        if names:
            return names
    return list(KNOWN_PADS)


def strip_comments(text):
    return _COMMENT_RE.sub(" ", text)


def source_files(design_dir):
    design_dir = Path(design_dir)
    files = []
    for g in SOURCE_GLOBS:
        files.extend(sorted(design_dir.glob(g)))
    return files


def find_pad_refs(text, pads):
    """[(pad, line_no)] for every pad name token in comment-stripped text."""
    hits = []
    stripped = strip_comments(text)
    for pad in pads:
        for m in re.finditer(r"(?<![A-Za-z0-9_$])" + re.escape(pad) + r"(?![A-Za-z0-9_$])", stripped):
            line_no = stripped.count("\n", 0, m.start()) + 1
            hits.append((pad, line_no))
    return sorted(set(hits), key=lambda h: (h[1], h[0]))


def declared_modules(text):
    return _MODULE_RE.findall(strip_comments(text))


def all_design_ids(designs_root=DESIGNS_ROOT):
    """{design_id: [folder names]} over designs/*/design.toml (unparseable files are skipped here;
    their own check reports them)."""
    ids = {}
    root = Path(designs_root)
    if not root.is_dir():
        return ids
    for toml in sorted(root.glob("*/design.toml")):
        try:
            d = design_toml.load_design(toml)
        except design_toml.DesignError:
            continue
        ids.setdefault(d.design_id, []).append(toml.parent.name)
    return ids


def check_design(design_dir, designs_root=DESIGNS_ROOT, pcf_path=DEFAULT_PCF):
    """Return (design or None, [errors]) for one design folder."""
    design_dir = Path(design_dir)
    errors = []
    if not design_dir.is_dir():
        return None, [f"{design_dir} is not a directory"]
    try:
        design = design_toml.load_design(design_dir)
    except design_toml.DesignError as exc:
        return None, [str(exc)]

    if design.name != design_dir.name:
        errors.append(f"design.name {design.name!r} != folder name {design_dir.name!r}")

    others = [n for n in all_design_ids(designs_root).get(design.design_id, []) if n != design_dir.name]
    if others:
        errors.append(f"design_id {design.design_id} is also used by designs/{', designs/'.join(others)}")
    if design.name == "template" and design_dir.parent == Path(designs_root):
        pass  # the template is a real design; new-design re-allocates its id

    files = source_files(design_dir)
    if design.is_stock:
        if not files:
            errors.append("stock design has no Verilog sources")
        return design, errors

    if not files:
        errors.append("no Verilog sources (*.v) in the design folder")
    pads = pad_names(pcf_path)
    modules = []
    for f in files:
        text = f.read_text(encoding="utf-8", errors="replace")
        rel = f.relative_to(design_dir.parent) if design_dir.parent in f.parents else f
        for pad, line_no in find_pad_refs(text, pads):
            errors.append(f"{rel}:{line_no}: references pad {pad} (rule 1/4: pads belong to fw2_shell)")
        modules.extend(declared_modules(text))
        for top in FORBIDDEN_TOPS:
            if top in declared_modules(text):
                errors.append(f"{rel}: declares module {top}; a user design's top is always fw2_shell (rule 1)")
    if files and USER_TOP not in modules:
        errors.append(f"no file declares `module {USER_TOP}` (rule 1: user logic lives in user_core)")
    return design, errors


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("design", nargs="+", help="design folder(s), e.g. designs/hello_blink")
    p.add_argument("--designs-root", default=str(DESIGNS_ROOT), help="for the design_id uniqueness check")
    p.add_argument("--pcf", default=str(DEFAULT_PCF), help="pad names source (falls back to the known list)")
    a = p.parse_args(argv)
    failed = 0
    for d in a.design:
        design, errors = check_design(d, Path(a.designs_root), Path(a.pcf))
        if errors:
            failed += 1
            for e in errors:
                print(f"FAIL {d}: {e}", file=sys.stderr)
        else:
            print(f"OK {d}: {design.name} v{design.version_str} id {design.design_id} ({design.kind})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
