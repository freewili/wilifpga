#!/usr/bin/env python3
"""Contract rule 8: is this .fwfpga sane, and does its header match its design.toml?

    python tools/check_container.py build/designs/hello_blink/hello_blink.fwfpga [--design designs/hello_blink] [--allow-size]

Checks: magic, format_version, header CRC-32, bitstream CRC-32 and SHA-256,
iCE40 preamble, size bounds, reserved bytes, field ranges, kind/design_id
rules, manifest is JSON, and -- when a design.toml is given or found under
designs/<header name>/ -- every header field equals the design.toml. Runs
after `fwfpga build` and before `fwfpga install`.
"""
import sys
from pathlib import Path

import design_toml
import fwfpga_format as ff
import pack_fwfpga

REPO_ROOT = Path(__file__).resolve().parents[1]
DESIGNS_ROOT = REPO_ROOT / "designs"

COMPARED_FIELDS = ("name", "description", "design_id", "design_version", "capabilities",
                   "clock_code", "io_profile", "kind", "contract_version")


def compare_with_design(header, design):
    """List of 'field: header X != design.toml Y' strings (empty when equal)."""
    expected = pack_fwfpga.header_from_design(design)
    errors = []
    for f in COMPARED_FIELDS:
        hv, dv = getattr(header, f), getattr(expected, f)
        if hv != dv:
            fmt = (lambda v: f"0x{v:08X}") if f == "io_profile" else repr
            errors.append(f"{f}: header {fmt(hv)} != design.toml {fmt(dv)}")
    return errors


def find_design_toml(name, designs_root=DESIGNS_ROOT):
    candidate = Path(designs_root) / name / "design.toml"
    return candidate if candidate.is_file() else None


def check(blob, design=None, allow_size=False):
    """Return (header or None, [errors], [notes])."""
    errors, notes = [], []
    try:
        header, manifest, bitstream = ff.validate(blob, size_bounds=not allow_size)
    except ff.FormatError as exc:
        return None, [str(exc)], notes
    if design is not None:
        errors.extend(compare_with_design(header, design))
        if not errors:
            notes.append(f"header matches {design.path or 'design.toml'}")
    else:
        notes.append("no design.toml given or found; header-vs-design comparison skipped")
    if manifest:
        notes.append(f"manifest {len(manifest)} bytes")
    return header, errors, notes


def check_file(path, design_path=None, allow_size=False, designs_root=DESIGNS_ROOT):
    """Convenience: returns (header, errors, notes). Resolves design.toml by header name when not given."""
    blob = Path(path).read_bytes()
    design = None
    if design_path:
        design = design_toml.load_design(design_path)
    else:
        try:
            header = ff.Header.from_bytes(blob)
        except ff.FormatError:
            header = None
        if header is not None:
            found = find_design_toml(header.name, designs_root)
            if found:
                design = design_toml.load_design(found)
    return check(blob, design, allow_size)


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("container", help=".fwfpga file")
    p.add_argument("--design", help="design.toml or design dir to compare against (default: designs/<name>/)")
    p.add_argument("--designs-root", default=str(DESIGNS_ROOT))
    p.add_argument("--allow-size", action="store_true", help="skip the 100 KB..1 MB bitstream bound (tests)")
    p.add_argument("-q", "--quiet", action="store_true")
    a = p.parse_args(argv)
    try:
        header, errors, notes = check_file(a.container, a.design, a.allow_size, Path(a.designs_root))
    except (design_toml.DesignError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    if not a.quiet and header is not None:
        print(ff.describe(header))
    for n in notes:
        print(f"note: {n}")
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    if errors:
        return 1
    print(f"OK: {a.container}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
