#!/usr/bin/env python3
"""Load and validate a design's `design.toml` (contract rule 2).

    python tools/design_toml.py designs/hello_blink/design.toml   # validate, print the summary

Schema (documented in docs/fwfpga-format.md):

    [design]
    name = "hello_blink"          # <=31 ASCII, required
    description = "..."           # <=127 ASCII, required, no default
    version = "001"               # exactly three digits
    design_id = 1                 # u16; 0xFFFF reserved for kind = "stock"
    kind = "user"                 # "user" | "stock" (default "user")
    clock_hz = 31250000           # one of CLOCK_CODES
    capabilities = ["IO_BUFFER"]  # names from CAPABILITIES (may be empty)
    repository = "https://..."    # required
    [io_profile]                  # all ten signals, mode names (tools/profile.py)
    spi_miso = "PASS_IN" ...

Every other tool (gen_design_id, pack_fwfpga, check_design, check_container,
fwfpga build) goes through load_design() so one validator owns the rules.
"""
import re
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

import profile as iop

CONTRACT_VERSION = 1

# clock_code -> FPGA_CLK rate requested from the RP2350 GPOUT. Code 0 is the
# stock 31.25 MHz (nominal; the stock divider gives 31.245 MHz).
CLOCK_CODES = {0: 31_250_000, 1: 12_500_000, 2: 25_000_000, 3: 48_000_000}
CLOCK_HZ_TO_CODE = {hz: code for code, hz in CLOCK_CODES.items()}

CAPABILITIES = {"IO_BUFFER": 1, "STREAM": 2, "PSRAM_SWAP": 4, "CM0": 8, "I2C_SLAVE": 16, "PIO_LINK": 32}
CAPABILITY_NAMES = {v: k for k, v in CAPABILITIES.items()}

KINDS = {"user": 0, "stock": 1}
KIND_NAMES = {v: k for k, v in KINDS.items()}
STOCK_DESIGN_ID = 0xFFFF

NAME_MAX = 31
DESCRIPTION_MAX = 127
NAME_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*$")

REQUIRED_KEYS = ("name", "description", "version", "design_id", "clock_hz", "capabilities", "repository")
# Build hints (all optional): `top` overrides the kind default (fw2_shell / main); `sources` lists the
# design's own Verilog files relative to the design folder instead of every *.v in it; `include_dirs`
# adds repo-relative -I directories.
OPTIONAL_KEYS = ("kind", "top", "sources", "include_dirs")
# Free-form tables carried into the container manifest but not validated here.
EXTRA_TABLES = ("registers", "host")


class DesignError(ValueError):
    pass


@dataclass
class Design:
    name: str
    description: str
    version: int            # 0..999
    version_str: str        # "001"
    design_id: int
    kind: str               # "user" | "stock"
    clock_hz: int
    capabilities: list      # names, in CAPABILITIES order
    repository: str
    io_profile: dict        # {signal: mode name}
    extras: dict = field(default_factory=dict)
    path: Path = None
    top: str = None                              # build hint; None = kind default
    sources: list = field(default_factory=list)  # build hint; [] = every *.v in the design folder
    include_dirs: list = field(default_factory=list)  # build hint; repo-relative

    @property
    def clock_code(self):
        return CLOCK_HZ_TO_CODE[self.clock_hz]

    @property
    def caps_byte(self):
        return caps_to_byte(self.capabilities)

    @property
    def kind_code(self):
        return KINDS[self.kind]

    @property
    def io_profile_packed(self):
        return iop.pack(self.io_profile)

    @property
    def is_stock(self):
        return self.kind == "stock"

    def toml_echo(self):
        """The validated content as plain dicts (for the container manifest)."""
        d = {
            "design": {
                "name": self.name, "description": self.description, "version": self.version_str,
                "design_id": self.design_id, "kind": self.kind, "clock_hz": self.clock_hz,
                "capabilities": list(self.capabilities), "repository": self.repository,
            },
            "io_profile": dict(self.io_profile),
        }
        for key in ("top", "sources", "include_dirs"):
            v = getattr(self, key)
            if v:
                d["design"][key] = v
        d.update(self.extras)
        return d


def caps_to_byte(names):
    value = 0
    for n in names:
        value |= CAPABILITIES[n]
    return value


def caps_from_byte(value):
    if value & ~sum(CAPABILITIES.values()):
        raise DesignError(f"capabilities 0x{value:02X} has unknown bits")
    return [n for n, bit in CAPABILITIES.items() if value & bit]


def _ascii(text, what, maxlen, allow_empty=False):
    if not isinstance(text, str):
        raise DesignError(f"{what} must be a string")
    if not text and not allow_empty:
        raise DesignError(f"{what} is required and may not be empty")
    if len(text) > maxlen:
        raise DesignError(f"{what} is {len(text)} chars; max {maxlen}")
    if any(ord(c) < 0x20 or ord(c) > 0x7E for c in text):
        raise DesignError(f"{what} must be printable ASCII")
    return text


def from_dict(data, path=None):
    """Validate a parsed TOML document and return a Design. Raises DesignError."""
    if not isinstance(data, dict):
        raise DesignError("design.toml must be a table")
    unknown_tables = [k for k in data if k not in ("design", "io_profile") + EXTRA_TABLES]
    if unknown_tables:
        raise DesignError("unknown top-level table(s): " + ", ".join(sorted(unknown_tables)))
    if "design" not in data:
        raise DesignError("missing [design] table")
    if "io_profile" not in data:
        raise DesignError("missing [io_profile] table")
    d = data["design"]
    if not isinstance(d, dict):
        raise DesignError("[design] must be a table")
    missing = [k for k in REQUIRED_KEYS if k not in d]
    if missing:
        raise DesignError("[design] is missing: " + ", ".join(missing))
    unknown = [k for k in d if k not in REQUIRED_KEYS + OPTIONAL_KEYS]
    if unknown:
        raise DesignError("[design] has unknown key(s): " + ", ".join(sorted(unknown)))

    name = _ascii(d["name"], "design.name", NAME_MAX)
    if not NAME_RE.match(name):
        raise DesignError(f"design.name {name!r} may only use letters, digits, '_', '.', '-'")
    description = _ascii(d["description"], "design.description", DESCRIPTION_MAX)

    version_str = d["version"]
    if not isinstance(version_str, str) or not re.fullmatch(r"[0-9]{3}", version_str):
        raise DesignError(f"design.version must be a string of exactly three digits, got {version_str!r}")

    design_id = d["design_id"]
    if isinstance(design_id, bool) or not isinstance(design_id, int) or not 0 <= design_id <= 0xFFFF:
        raise DesignError(f"design.design_id must be an integer 0..65535, got {design_id!r}")

    kind = d.get("kind", "user")
    if kind not in KINDS:
        raise DesignError(f"design.kind must be one of {', '.join(KINDS)}, got {kind!r}")
    if kind == "stock" and design_id != STOCK_DESIGN_ID:
        raise DesignError("kind = \"stock\" requires design_id = 0xFFFF (65535)")
    if kind == "user" and design_id == STOCK_DESIGN_ID:
        raise DesignError("design_id 0xFFFF is reserved for kind = \"stock\"")

    clock_hz = d["clock_hz"]
    if isinstance(clock_hz, bool) or not isinstance(clock_hz, int) or clock_hz not in CLOCK_HZ_TO_CODE:
        raise DesignError(f"design.clock_hz must be one of {sorted(CLOCK_HZ_TO_CODE)}, got {clock_hz!r}")

    caps = d["capabilities"]
    if not isinstance(caps, list) or not all(isinstance(c, str) for c in caps):
        raise DesignError("design.capabilities must be a list of strings")
    bad = [c for c in caps if c not in CAPABILITIES]
    if bad:
        raise DesignError("design.capabilities has unknown name(s): " + ", ".join(bad)
                          + "; known: " + ", ".join(CAPABILITIES))
    if len(set(caps)) != len(caps):
        raise DesignError("design.capabilities lists a capability twice")
    caps = [c for c in CAPABILITIES if c in caps]
    # The CM0 link is a UART at FPGA_CLK / 4 against the CM0's fixed 7.8125 Mbaud:
    # only 31.25 MHz carries it. The firmware refuses the same (clock-code-cm0).
    if "CM0" in caps and clock_hz != 31250000:
        raise DesignError("capability CM0 needs clock_hz = 31250000 (the CM0 UART runs at FPGA_CLK / 4)")

    repository = _ascii(d["repository"], "design.repository", 255)

    top = d.get("top")
    if top is not None and (not isinstance(top, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", top)):
        raise DesignError(f"design.top must be a Verilog module name, got {top!r}")
    sources = d.get("sources", [])
    include_dirs = d.get("include_dirs", [])
    for key, lst in (("sources", sources), ("include_dirs", include_dirs)):
        if not isinstance(lst, list) or not all(isinstance(s, str) and s for s in lst):
            raise DesignError(f"design.{key} must be a list of non-empty strings")

    try:
        io_profile = dict(iop.validate(data["io_profile"]))
    except iop.ProfileError as exc:
        raise DesignError(str(exc)) from exc

    extras = {k: data[k] for k in EXTRA_TABLES if k in data}
    return Design(name=name, description=description, version=int(version_str), version_str=version_str,
                  design_id=design_id, kind=kind, clock_hz=clock_hz, capabilities=caps,
                  repository=repository, io_profile=io_profile, extras=extras,
                  path=Path(path) if path else None, top=top, sources=list(sources),
                  include_dirs=list(include_dirs))


def load_design(path):
    """Read designs/<x>/design.toml (or the design directory) -> Design."""
    path = Path(path)
    if path.is_dir():
        path = path / "design.toml"
    if not path.is_file():
        raise DesignError(f"{path} not found")
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as exc:
        raise DesignError(f"{path}: {exc}") from exc
    except UnicodeDecodeError as exc:
        raise DesignError(f"{path}: not UTF-8 ({exc})") from exc
    try:
        return from_dict(data, path)
    except DesignError as exc:
        raise DesignError(f"{path}: {exc}") from exc


def describe(design):
    lines = [
        f"name:         {design.name}",
        f"description:  {design.description}",
        f"version:      {design.version_str}",
        f"design_id:    {design.design_id} (0x{design.design_id:04X})",
        f"kind:         {design.kind}",
        f"clock:        {design.clock_hz} Hz (code {design.clock_code})",
        f"capabilities: {', '.join(design.capabilities) or '(none)'} (0x{design.caps_byte:02X})",
        f"io_profile:   0x{design.io_profile_packed:08X}  {iop.summary(design.io_profile)}",
        f"repository:   {design.repository}",
    ]
    return "\n".join(lines)


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("design", help="design.toml or a design directory")
    a = p.parse_args(argv)
    try:
        design = load_design(a.design)
    except DesignError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(describe(design))
    return 0


if __name__ == "__main__":
    sys.exit(main())
