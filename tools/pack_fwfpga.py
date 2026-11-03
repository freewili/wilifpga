#!/usr/bin/env python3
"""design.toml + iCE40 .bin [+ manifest JSON] -> <name>.fwfpga

    python tools/pack_fwfpga.py designs/hello_blink/design.toml build/designs/hello_blink/hello_blink.bin \\
        -o build/designs/hello_blink/hello_blink.fwfpga [--manifest extra.json] [--no-manifest] [--allow-size]

Refuses a bitstream without the iCE40 preamble (7E AA 99 7E within the first
64 bytes) and one outside 100 KB..1 MB unless --allow-size (tests only). The
header is filled from the same Design object gen_design_id.py uses for the
fabric's ID block, so the two cannot disagree unless someone edits one by hand.
"""
import datetime
import json
import os
import sys
from pathlib import Path

import design_toml
import fwfpga_format as ff

PACKER = "wilifpga tools/pack_fwfpga.py"
MANIFEST_FORMAT = "fwfpga-manifest/1"


class PackError(ValueError):
    pass


def header_from_design(design):
    return ff.Header(
        name=design.name, description=design.description, design_id=design.design_id,
        design_version=design.version, capabilities=design.caps_byte, clock_code=design.clock_code,
        io_profile=design.io_profile_packed, kind=design.kind_code,
        contract_version=design_toml.CONTRACT_VERSION)


def build_timestamp():
    """ISO-8601 UTC; SOURCE_DATE_EPOCH makes it reproducible."""
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if epoch:
        t = datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc)
    else:
        t = datetime.datetime.now(datetime.timezone.utc)
    return t.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def build_manifest(design, extra=None, tool_versions=None, timestamp=None):
    """The host-only JSON blob: design.toml echo, tool versions, build time, repository."""
    manifest = {
        "format": MANIFEST_FORMAT,
        "packer": PACKER,
        "built": timestamp or build_timestamp(),
        "repository": design.repository,
        "design": design.toml_echo(),
        "tools": dict(tool_versions or {}),
    }
    if extra:
        for k, v in extra.items():
            if k == "design":
                raise PackError("manifest extra may not override 'design'")
            manifest[k] = v
    return manifest


def check_bitstream(bitstream, allow_size=False):
    if not ff.has_preamble(bitstream):
        raise PackError("not an iCE40 bitstream: no 7E AA 99 7E preamble in the first 64 bytes")
    if not allow_size and not ff.BITSTREAM_MIN <= len(bitstream) <= ff.BITSTREAM_MAX:
        raise PackError(f"bitstream is {len(bitstream)} bytes; expected {ff.BITSTREAM_MIN}..{ff.BITSTREAM_MAX} "
                        "(--allow-size to override, tests only)")


def pack_design(design, bitstream, manifest=None, allow_size=False):
    """Design + bitstream bytes (+ manifest dict or None) -> container bytes, validated."""
    check_bitstream(bitstream, allow_size)
    blob = ff.pack(header_from_design(design), manifest, bitstream)
    ff.validate(blob, size_bounds=not allow_size)
    return blob


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("design", help="design.toml or design directory")
    p.add_argument("bitstream", help="iCE40 .bin from icepack")
    p.add_argument("-o", "--out", help="output .fwfpga (default: next to the .bin, named <design name>.fwfpga)")
    p.add_argument("--manifest", help="JSON file merged into the manifest")
    p.add_argument("--no-manifest", action="store_true", help="manifest_len = 0")
    p.add_argument("--tool-versions", help="JSON object of tool -> version for the manifest")
    p.add_argument("--allow-size", action="store_true", help="skip the 100 KB..1 MB bitstream bound (tests)")
    a = p.parse_args(argv)
    try:
        design = design_toml.load_design(a.design)
        bitstream = Path(a.bitstream).read_bytes()
        if a.no_manifest:
            manifest = None
        else:
            extra = json.loads(Path(a.manifest).read_text(encoding="utf-8")) if a.manifest else None
            tools = json.loads(a.tool_versions) if a.tool_versions else None
            manifest = build_manifest(design, extra, tools)
        blob = pack_design(design, bitstream, manifest, a.allow_size)
    except (design_toml.DesignError, ff.FormatError, PackError, OSError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    out = Path(a.out) if a.out else Path(a.bitstream).with_name(design.name + ".fwfpga")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(blob)
    print(f"wrote {out} ({len(blob)} bytes: header 256 + manifest {len(blob) - 256 - len(bitstream)} "
          f"+ bitstream {len(bitstream)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
