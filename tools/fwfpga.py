#!/usr/bin/env python3
r"""fwfpga -- build, simulate, install and drive FreeWili 2 FPGA designs.

  fwfpga toolchain check|install        pinned oss-cad-suite (yosys, nextpnr-ice40, icepack, iverilog, verilator)
  fwfpga new-design <name>              scaffold designs/<name> from designs/template, allocate a design_id
  fwfpga build <design> [--freq MHz]    synth + pnr + timing check + pack -> build/designs/<name>/<name>.fwfpga
  fwfpga lint <design>                  verilator --lint-only -Wall over shell + design
  fwfpga sim <design>                   iverilog + vvp over designs/<name>/tb/*.v (nonzero on $fatal)
  fwfpga inspect <file.fwfpga>          print the container header and direction summary
  fwfpga install <design|file>          check_container, then file put to /fpga/<name>.fwfpga over USB serial
  fwfpga load <design|file|/dev/path>   h\f\l "<path>"    fwfpga restore -> h\f\t    fwfpga status -> h\f\s
  fwfpga reg r <addr> [count] | reg w <addr> <bytes>   h\f\r <addr> <count> / h\f\w <addr> <bytes>
  fwfpga stream rx <n> [-o file]        h\f\x <n>

Device protocol (bench-confirmed 2026-10-31): 115200 baud; 0x03 returns the menu to its root; a command is
the wire path plus arguments and "\n"; replies are framed `[<path> <ts> <seq> <payload> <0|1>]`.
File upload: `h\x\f <devpath> <size> <crc32>` (decimal), wait for "Send File Now", stream the raw bytes.
  fwfpga test [--no-sim]                pytest over tools/tests and tests/ (+ sim of designs with a tb/)

Global: --print runs nothing and prints every external command / every byte that would go to the
device; --port COMx overrides MAIN auto-detection (USB VID 0x093C PID 0x205A); --repo <dir> for tests.
Toolchain lookup order: $OSS_CAD_SUITE (the suite dir or its bin/), then
~/.oss-cad-suite/<release>/oss-cad-suite/bin, then PATH.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import time
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import check_container  # noqa: E402
import check_design  # noqa: E402
import design_toml  # noqa: E402
import fwfpga_format as ff  # noqa: E402
import gen_design_id  # noqa: E402
import pack_fwfpga  # noqa: E402
import profile as iop  # noqa: E402

# --------------------------------------------------------------------------- constants

OSS_CAD_SUITE_RELEASE = "2026-10-31"
OSS_CAD_SUITE_ROOT = Path(os.environ.get("OSS_CAD_SUITE_ROOT", Path.home() / ".oss-cad-suite"))
OSS_CAD_SUITE_URL = "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/{release}/{archive}"
TOOLCHAIN_TOOLS = ("yosys", "nextpnr-ice40", "icepack", "iverilog", "vvp", "verilator")
TOOL_VERSION_ARGS = {"yosys": ["-V"], "nextpnr-ice40": ["--version"], "iverilog": ["-V"], "vvp": ["-V"],
                     "verilator": ["--version"], "icepack": None}

DEVICE = "up5k"
PACKAGE = "sg48"
PCF = "fpga/constraints/fw2.pcf"
SHELL_TOP = "fw2_shell"
STOCK_TOP = "main"

MAIN_VID, MAIN_PID = 0x093C, 0x205A
BAUD = 115200
MENU_RESET = b"\x03"
FPGA_MENU = r"h\f"
CAPTURE_DEVPATH = "\\fpga\\cap.bin"   # where h\f\c writes; backslashes: the device file API wants them
PIO_CAPTURE_DEVPATH = "\\fpga\\pio.bin"
PIO_BURST_BYTES = 32768                  # the firmware stages the PIO link in 32 KB SRAM bursts

WIRE = {
    # `h\f\d` was the draft; the menu system reserves `d` globally, so Restore Stock is `t`.
    "load": r"h\f\l", "restore": r"h\f\t", "status": r"h\f\s", "reg_r": r"h\f\r", "reg_w": r"h\f\w",
    "stream_rx": r"h\f\x", "file_put": r"h\x\f", "file_get": r"h\x\u", "capture": r"h\f\c", "pio_capture": r"h\f\p", "link_stream": r"h\f\k",
}
DEVICE_FPGA_DIR = "/fpga"
PUT_CHUNK = 4096
QUOTE_PUT_PATH = False      # onewili and the bench console send the put path unquoted; h\f\l takes quotes


class CliError(Exception):
    pass


# --------------------------------------------------------------------------- repo paths

class Repo:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.designs = self.root / "designs"
        self.fpga = self.root / "fpga"
        self.shell = self.fpga / "shell"
        self.lib = self.fpga / "lib"
        self.sim = self.fpga / "sim"
        self.pcf = self.root / PCF
        self.build = self.root / "build" / "designs"

    def rel(self, path):
        """Path relative to the repo root with forward slashes (what we hand to the tools, cwd = root)."""
        p = Path(path)
        try:
            p = p.resolve().relative_to(self.root)
        except ValueError:
            pass
        return p.as_posix()

    def design_dir(self, name):
        d = self.designs / name
        if not d.is_dir():
            raise CliError(f"no such design: designs/{name}")
        return d

    def shell_sources(self):
        return sorted(self.shell.glob("*.v")) if self.shell.is_dir() else []

    def lib_sources(self, exclude_fw2=False):
        """Every module under fpga/lib; unused ones are dropped by `synth_ice40 -top`. Stock designs skip
        the new fw2_* modules, which depend on the shell's includes."""
        if not self.lib.is_dir():
            return []
        files = sorted(self.lib.rglob("*.v"))
        if exclude_fw2:
            files = [f for f in files if not f.name.startswith("fw2_")]
        return files

    def lib_include_dirs(self):
        """fpga/lib/<module>/ directories that hold a .vh (library modules that include from their own dir)."""
        if not self.lib.is_dir():
            return []
        return sorted({p.parent for p in self.lib.rglob("*.vh")})

    def sim_sources(self):
        """Bus-functional models and helpers (not the tb_*.v tops)."""
        if not self.sim.is_dir():
            return []
        return sorted(p for p in self.sim.glob("*.v") if not p.name.startswith("tb_"))

    @staticmethod
    def design_sources(design_dir, design=None):
        """The design's own Verilog: design.toml `sources` (relative to the folder) or every *.v in it."""
        design_dir = Path(design_dir)
        if design is not None and design.sources:
            files = []
            for pattern in design.sources:
                hits = sorted(design_dir.glob(pattern)) if any(c in pattern for c in "*?[") else [design_dir / pattern]
                for h in hits:
                    if not h.is_file():
                        raise CliError(f"design.toml sources entry {pattern!r} not found in {design_dir}")
                    files.append(h)
            return files
        return sorted(design_dir.glob("*.v"))

    @staticmethod
    def tb_sources(design_dir):
        tb = Path(design_dir) / "tb"
        return sorted(list(tb.glob("*.v")) + list(tb.glob("*.sv"))) if tb.is_dir() else []


# --------------------------------------------------------------------------- toolchain

def _exe(path):
    if os.name == "nt" and not str(path).lower().endswith(".exe") and Path(str(path) + ".exe").exists():
        return Path(str(path) + ".exe")
    return Path(path)


def oss_cad_suite_dir():
    """The suite directory (contains bin/ and lib/) or None. Env override first, then the pinned install."""
    env = os.environ.get("OSS_CAD_SUITE")
    if env:
        p = Path(env)
        if p.name == "bin":
            p = p.parent
        return p if (p / "bin").is_dir() else None
    pinned = OSS_CAD_SUITE_ROOT / OSS_CAD_SUITE_RELEASE / "oss-cad-suite"
    return pinned if (pinned / "bin").is_dir() else None


def tool_env():
    """PATH with the suite's bin and lib first; the Windows launchers need lib/ on PATH."""
    env = dict(os.environ)
    suite = oss_cad_suite_dir()
    if suite:
        env["PATH"] = os.pathsep.join([str(suite / "bin"), str(suite / "lib"), env.get("PATH", "")])
        env.setdefault("YOSYSHQ_ROOT", str(suite) + os.sep)
        # verilator_bin.exe on Windows looks for verilated_std.sv under a baked-in /yosyshq prefix;
        # VERILATOR_ROOT points it at the suite's copy (harmless elsewhere).
        vroot = suite / "share" / "verilator"
        if (vroot / "include" / "verilated_std.sv").is_file():
            env.setdefault("VERILATOR_ROOT", str(vroot))
    return env


def tool_path(name):
    """Absolute path of a toolchain executable or None."""
    suite = oss_cad_suite_dir()
    candidates = [name]
    if name == "verilator":
        candidates = ["verilator_bin", "verilator"] if os.name == "nt" else ["verilator", "verilator_bin"]
    for c in candidates:
        if suite:
            p = _exe(suite / "bin" / c)
            if p.exists():
                return p
        found = shutil.which(c)
        if found:
            return Path(found)
    return None


def tool_version(name):
    """First line of the tool's version output, or an explanation."""
    path = tool_path(name)
    if path is None:
        return None
    args = TOOL_VERSION_ARGS.get(name)
    if args is None:
        return f"present ({path})"
    try:
        r = subprocess.run([str(path)] + args, capture_output=True, text=True, env=tool_env(), timeout=60,
                           encoding="utf-8", errors="replace")
    except (OSError, subprocess.TimeoutExpired) as exc:
        return f"error running {path}: {exc}"
    text = (r.stdout + r.stderr).strip()
    return text.splitlines()[0] if text else f"present ({path})"


def ice40_cells_sim():
    """yosys's iCE40 primitive models (SB_SPRAM256KA, SB_IO, ...) for iverilog, or None.
    $ICE40_CELLS_SIM overrides; otherwise <suite>/share/yosys/ice40/cells_sim.v."""
    env = os.environ.get("ICE40_CELLS_SIM")
    if env:
        return Path(env)
    suite = oss_cad_suite_dir()
    if suite:
        p = suite / "share" / "yosys" / "ice40" / "cells_sim.v"
        if p.is_file():
            return p
    yosys = tool_path("yosys")
    if yosys:
        p = yosys.parent.parent / "share" / "yosys" / "ice40" / "cells_sim.v"
        if p.is_file():
            return p
    return None


def toolchain_archive_name(release=OSS_CAD_SUITE_RELEASE, system=None, machine=None):
    system = (system or platform.system()).lower()
    machine = (machine or platform.machine()).lower()
    osname = {"windows": "windows", "linux": "linux", "darwin": "darwin"}.get(system)
    if osname is None:
        raise CliError(f"no oss-cad-suite build for {system}")
    arch = "arm64" if machine in ("arm64", "aarch64") else "x64"
    return f"oss-cad-suite-{osname}-{arch}-{release.replace('-', '')}.tgz"


def cmd_toolchain(args):
    if args.action == "check":
        suite = oss_cad_suite_dir()
        print(f"pinned release: {OSS_CAD_SUITE_RELEASE}")
        print(f"suite dir:      {suite or '(not installed; using PATH)'}")
        missing = []
        for t in TOOLCHAIN_TOOLS:
            v = tool_version(t)
            print(f"  {t:<14} {v or 'MISSING'}")
            if v is None:
                missing.append(t)
        if missing:
            print(f"missing: {', '.join(missing)} -> run `fwfpga toolchain install` or set OSS_CAD_SUITE")
            return 1
        return 0
    # install
    dest = OSS_CAD_SUITE_ROOT / OSS_CAD_SUITE_RELEASE
    if (dest / "oss-cad-suite" / "bin").is_dir() and not args.force:
        print(f"already installed: {dest / 'oss-cad-suite'}")
        return 0
    archive = toolchain_archive_name()
    url = OSS_CAD_SUITE_URL.format(release=OSS_CAD_SUITE_RELEASE, archive=archive)
    archive_path = dest / archive
    if args.print:
        print(f"download {url} -> {archive_path}")
        print(f"extract {archive_path} -> {dest} (expects top folder oss-cad-suite)")
        return 0
    dest.mkdir(parents=True, exist_ok=True)
    if not archive_path.exists():
        print(f"downloading {url}")
        _download(url, archive_path)
    digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    print(f"sha256 {digest}")
    if args.sha256 and args.sha256.lower() != digest:
        raise CliError(f"sha256 mismatch: expected {args.sha256}")
    print(f"extracting to {dest}")
    with tarfile.open(archive_path, "r:gz") as tar:
        if hasattr(tarfile, "data_filter"):
            tar.extractall(dest, filter="data")
        else:
            tar.extractall(dest)
    if not (dest / "oss-cad-suite" / "bin").is_dir():
        raise CliError(f"archive did not produce {dest / 'oss-cad-suite' / 'bin'}")
    if not args.keep_archive:
        archive_path.unlink()
    print(f"installed {dest / 'oss-cad-suite'}")
    return cmd_toolchain(argparse.Namespace(action="check", print=False))


def _download(url, path):
    import urllib.request
    tmp = path.with_suffix(".part")
    with urllib.request.urlopen(url) as resp, open(tmp, "wb") as out:
        total = int(resp.headers.get("Content-Length") or 0)
        done = 0
        last = 0
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
            done += len(chunk)
            if total and done - last >= (50 << 20):
                last = done
                print(f"  {done / 1e6:.0f} / {total / 1e6:.0f} MB")
    tmp.replace(path)


# --------------------------------------------------------------------------- running tools

class Runner:
    def __init__(self, repo, print_only=False):
        self.repo = repo
        self.print_only = print_only

    def run(self, cmd, check=True, capture=False):
        cmd = [str(c) for c in cmd]
        line = " ".join(shlex.quote(c) if " " in c or ";" in c else c for c in cmd)
        if self.print_only:
            print(line)
            return subprocess.CompletedProcess(cmd, 0, "", "")
        print(f"+ {line}", flush=True)
        r = subprocess.run(cmd, cwd=str(self.repo.root), env=tool_env(), capture_output=capture,
                           text=True, encoding="utf-8", errors="replace")
        if check and r.returncode != 0:
            if capture:
                sys.stdout.write(r.stdout or "")
                sys.stderr.write(r.stderr or "")
            raise CliError(f"{cmd[0]} failed with exit code {r.returncode}")
        return r

    def tool(self, name):
        p = tool_path(name)
        if p is None:
            if self.print_only:
                return name
            raise CliError(f"{name} not found; run `fwfpga toolchain install` or set OSS_CAD_SUITE")
        return p


# --------------------------------------------------------------------------- build / lint / sim

def _prepare(repo, name, print_only):
    """Load + check the design, generate fw2_design_id.vh; returns (design, design_dir, build_dir, top)."""
    ddir = repo.design_dir(name)
    design, errors = check_design.check_design(ddir, designs_root=repo.designs, pcf_path=repo.pcf)
    if errors:
        for e in errors:
            print(f"FAIL: {e}", file=sys.stderr)
        raise CliError(f"check_design failed for {name}")
    bdir = repo.build / name
    if print_only:
        print(f"# gen_design_id -> {repo.rel(bdir / 'fw2_design_id.vh')}")
    else:
        bdir.mkdir(parents=True, exist_ok=True)
        gen_design_id.write_vh(design, bdir / "fw2_design_id.vh")
    top = design.top or (STOCK_TOP if design.is_stock else SHELL_TOP)
    return design, ddir, bdir, top


def synth_sources(repo, design, ddir):
    """shell + lib + design for a user design; lib (minus fw2_*) + design for stock."""
    files = [] if design.is_stock else repo.shell_sources()
    files += repo.lib_sources(exclude_fw2=design.is_stock) + repo.design_sources(ddir, design)
    if not files:
        raise CliError("no Verilog sources found (fpga/shell, fpga/lib, designs/<name>)")
    return files


def include_dirs(repo, bdir, design=None):
    """fpga/shell, the build dir (fw2_design_id.vh), every lib dir with a .vh, then design.toml extras."""
    dirs = [repo.shell, bdir] + repo.lib_include_dirs()
    for extra in (design.include_dirs if design else []):
        p = repo.root / extra
        if p not in dirs:
            dirs.append(p)
    return dirs


def yosys_command(runner, repo, design, ddir, bdir, top):
    files = " ".join(repo.rel(f) for f in synth_sources(repo, design, ddir))
    incs = " ".join(f"-I{repo.rel(d)}" for d in include_dirs(repo, bdir, design))
    script = f"read_verilog {incs} {files}; synth_ice40 -top {top} -json {repo.rel(bdir / (design.name + '.json'))}"
    return [runner.tool("yosys"), "-q", "-l", repo.rel(bdir / "yosys.log"), "-p", script]


def nextpnr_command(runner, repo, design, bdir, freq_mhz):
    n = design.name
    return [runner.tool("nextpnr-ice40"), f"--{DEVICE}", "--package", PACKAGE, "--pcf", repo.rel(repo.pcf),
            "--json", repo.rel(bdir / f"{n}.json"), "--asc", repo.rel(bdir / f"{n}.asc"),
            "--freq", f"{freq_mhz:g}", "--report", repo.rel(bdir / "report.json"),
            "-q", "--log", repo.rel(bdir / "nextpnr.log")] + (
            # The stock gateware (kind = "stock", the single exempt design) was never
            # timing-constrained upstream and is proven on hardware at 31.25 MHz, yet
            # nextpnr's STA reports ~23.5 MHz for it. Let it place and route; rule 5
            # stays absolute for every user design. Policy: fpga/README.md.
            ["--timing-allow-fail"] if design.is_stock else [])


def icepack_command(runner, repo, design, bdir):
    n = design.name
    return [runner.tool("icepack"), repo.rel(bdir / f"{n}.asc"), repo.rel(bdir / f"{n}.bin")]


def fmax_results(report, required_mhz):
    """[(clock, achieved, constraint, passed)] from a nextpnr report.json; required_mhz is the floor."""
    out = []
    for clock, v in (report.get("fmax") or {}).items():
        achieved = float(v.get("achieved", 0.0))
        constraint = float(v.get("constraint", required_mhz))
        out.append((clock, achieved, constraint, achieved >= max(required_mhz, constraint) - 1e-6))
    return out


def utilisation_lines(report):
    util = report.get("utilization") or {}
    lines = []
    for cell in ("ICESTORM_LC", "ICESTORM_RAM", "ICESTORM_SPRAM", "ICESTORM_DSP", "ICESTORM_PLL", "SB_IO", "SB_GB"):
        v = util.get(cell)
        if v and (v.get("used") or cell in ("ICESTORM_LC", "SB_IO")):
            used, avail = v.get("used", 0), v.get("available", 0)
            pct = f"{100.0 * used / avail:5.1f}%" if avail else ""
            lines.append(f"  {cell:<15} {used:>5} / {avail:<5} {pct}")
    return lines


def summarise_report(report, required_mhz):
    """(text, ok). ok is False when any clock misses required_mhz or no clock was constrained."""
    lines = ["utilisation:"] + utilisation_lines(report)
    results = fmax_results(report, required_mhz)
    ok = True
    if not results:
        lines.append(f"Fmax: nextpnr reported no clock (is CLK constrained?) -- required {required_mhz:g} MHz")
        ok = False
    for clock, achieved, constraint, passed in results:
        lines.append(f"Fmax {clock}: {achieved:.2f} MHz (required {max(required_mhz, constraint):g} MHz) "
                     f"{'PASS' if passed else 'FAIL'}")
        ok = ok and passed
    return "\n".join(lines), ok


def cmd_build(args, repo):
    runner = Runner(repo, args.print)
    design, ddir, bdir, top = _prepare(repo, args.design, args.print)
    freq = args.freq if args.freq else design.clock_hz / 1e6
    runner.run(yosys_command(runner, repo, design, ddir, bdir, top))
    if not design.is_stock:
        # Every bidirectional pad of the synthesised netlist must be a real
        # tri-state SB_IO: yosys folds a constant-Z assign into a DRIVEN
        # constant (found on hardware as I2C SDA held low, 2026-10-31).
        runner.run([sys.executable, repo.rel(repo.fpga / "sim" / "check_netlist_pads.py"),
                    repo.rel(bdir / f"{design.name}.json")])
    runner.run(nextpnr_command(runner, repo, design, bdir, freq))
    runner.run(icepack_command(runner, repo, design, bdir))
    out = bdir / f"{design.name}.fwfpga"
    if args.print:
        print(f"# pack {repo.rel(bdir / (design.name + '.bin'))} + design.toml -> {repo.rel(out)}; check_container; "
              f"fail if Fmax < {freq:g} MHz")
        return 0
    report = json.loads((bdir / "report.json").read_text(encoding="utf-8"))
    text, timing_ok = summarise_report(report, freq)
    print(text)
    bitstream = (bdir / f"{design.name}.bin").read_bytes()
    tools = {t: (tool_version(t) or "missing") for t in ("yosys", "nextpnr-ice40", "icepack")}
    manifest = pack_fwfpga.build_manifest(design, extra={
        "build": {"freq_mhz": freq, "fmax": {c: a for c, a, _, _ in fmax_results(report, freq)},
                  "utilization": {k: v for k, v in (report.get("utilization") or {}).items() if v.get("used")},
                  "top": top},
    }, tool_versions=tools)
    blob = pack_fwfpga.pack_design(design, bitstream, manifest)
    header, errors, _ = check_container.check(blob, design)
    if errors:
        for e in errors:
            print(f"FAIL: {e}", file=sys.stderr)
        raise CliError("check_container failed on the freshly packed container")
    out.write_bytes(blob)
    print(f"wrote {repo.rel(out)} ({len(blob)} bytes, bitstream {len(bitstream)}); "
          f"{iop.summary(design.io_profile)}")
    if not timing_ok:
        if design.is_stock:
            print(f"warning: stock gateware did not meet {freq:g} MHz in nextpnr STA (exempt by policy, "
                  f"see fpga/README.md); container written", file=sys.stderr)
        else:
            raise CliError(f"timing not met at {freq:g} MHz (contract rule 5); container written but NOT release-grade")
    return 0


def cmd_lint(args, repo):
    runner = Runner(repo, args.print)
    design, ddir, bdir, top = _prepare(repo, args.design, args.print)
    cmd = [runner.tool("verilator"), "--lint-only", "-Wall", "--top-module", top]
    cmd += [f"-I{repo.rel(d)}" for d in include_dirs(repo, bdir, design)]
    for waivers in (repo.fpga / "shell" / "fw2_lint.vlt", repo.fpga / LINT_WAIVERS):
        if waivers.is_file():
            cmd.append(repo.rel(waivers))     # verilator config file: explicit lint_off rules
    # Lint only what the shell actually instantiates: other library modules
    # may be synthesis-only reference material and carry upstream warnings
    # that are not this design's problem.
    srcs = synth_sources(repo, design, ddir)
    if not design.is_stock:
        keep = ("spi_slave", "fw2_stream_fifo")
        srcs = [f for f in srcs if repo.lib not in f.parents or f.parent.name in keep]
    cmd += [repo.rel(f) for f in srcs]
    runner.run(cmd)
    if not args.print:
        print("lint clean")
    return 0


SHELL_TB = "shell"      # `fwfpga sim shell` runs fpga/sim/tb_shell.v against fpga/sim/tb_design/
LINT_WAIVERS = "lint.vlt"   # optional fpga/lint.vlt (verilator configuration file) passed to lint


def sim_cell_models(print_only):
    """The iCE40 primitive models iverilog needs for SB_* instances (SPRAM, IO, PLL)."""
    cells = ice40_cells_sim()
    if cells is None:
        if print_only:
            return ["<suite>/share/yosys/ice40/cells_sim.v"]
        raise CliError("cannot find yosys's ice40/cells_sim.v (needed to simulate SB_* primitives); "
                       "set ICE40_CELLS_SIM or install the toolchain")
    return [str(cells)]


def cmd_sim(args, repo):
    runner = Runner(repo, args.print)
    if args.design == SHELL_TB:
        tb_design = repo.sim / "tb_design"
        tbs = [repo.sim / "tb_shell.v"]
        if not tbs[0].is_file() or not tb_design.is_dir():
            raise CliError("fpga/sim/tb_shell.v or fpga/sim/tb_design/ is missing")
        bdir = repo.root / "build" / "sim"
        if not args.print:
            bdir.mkdir(parents=True, exist_ok=True)
        incs = [repo.shell, tb_design] + repo.lib_include_dirs()
        sources = repo.shell_sources() + repo.lib_sources() + sorted(tb_design.glob("*.v"))
        name = "tb_shell"
    else:
        design, ddir, bdir, top = _prepare(repo, args.design, args.print)
        tbs = repo.tb_sources(ddir)
        if not tbs:
            raise CliError(f"designs/{design.name}/tb/ has no testbench (*.v)")
        incs = include_dirs(repo, bdir, design)
        sources = synth_sources(repo, design, ddir)
        name = design.name
    vvp_file = bdir / "sim.vvp"
    cmd = [runner.tool("iverilog"), "-g2012", "-I", repo.rel(repo.sim)]
    cmd += [f"-I{repo.rel(d)}" for d in incs]
    cmd += ["-o", repo.rel(vvp_file)]
    cmd += [repo.rel(f) for f in tbs + repo.sim_sources() + sources]
    cmd += sim_cell_models(args.print)
    runner.run(cmd)
    r = runner.run([runner.tool("vvp"), "-N", repo.rel(vvp_file)], check=False, capture=True)
    if args.print:
        return 0
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    text = r.stdout + r.stderr
    if r.returncode != 0 or re.search(r"\$fatal|FATAL|\bERROR\b|\bFAIL\b", text):
        raise CliError(f"simulation {name} failed (vvp exit {r.returncode})")
    print(f"sim {name} passed")
    return 0


# --------------------------------------------------------------------------- new-design

NAME_RE = re.compile(r"^[a-z][a-z0-9_]{0,30}$")


def next_design_id(repo):
    ids = [i for i in check_design.all_design_ids(repo.designs) if i != design_toml.STOCK_DESIGN_ID]
    return (max(ids) + 1) if ids else 1


def new_design(repo, name, print_only=False):
    if not NAME_RE.match(name):
        raise CliError("design name must match [a-z][a-z0-9_]{0,30}")
    src = repo.designs / "template"
    dst = repo.designs / name
    if not src.is_dir():
        raise CliError("designs/template is missing")
    if dst.exists():
        raise CliError(f"designs/{name} already exists")
    design_id = next_design_id(repo)
    if print_only:
        print(f"copy designs/template -> designs/{name}; replace token 'template' -> '{name}'; design_id = {design_id}")
        return design_id
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "build"))
    for path in sorted(dst.rglob("*"), key=lambda p: -len(p.parts)):
        if path.is_file():
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            new = text.replace("template", name)
            if path.name == "design.toml":
                new = re.sub(r'(?m)^(\s*name\s*=\s*)"[^"]*"', rf'\g<1>"{name}"', new)
                new = re.sub(r"(?m)^(\s*design_id\s*=\s*)\S+", rf"\g<1>{design_id}", new)
            if new != text:
                path.write_text(new, encoding="utf-8")
        if "template" in path.name:
            path.rename(path.with_name(path.name.replace("template", name)))
    design, errors = check_design.check_design(dst, designs_root=repo.designs, pcf_path=repo.pcf)
    if errors:
        raise CliError("new design does not pass check_design: " + "; ".join(errors))
    print(f"created designs/{name} (design_id {design_id}); edit description/version/io_profile in design.toml")
    return design_id


def cmd_new_design(args, repo):
    new_design(repo, args.name, args.print)
    return 0


# --------------------------------------------------------------------------- inspect

def cmd_inspect(args, repo):
    blob = Path(args.file).read_bytes()
    try:
        header, manifest, _ = ff.validate(blob, size_bounds=False)
    except ff.FormatError as exc:
        raise CliError(str(exc))
    print(ff.describe(header))
    try:
        print(iop.table_text(iop.unpack(header.io_profile)))
    except iop.ProfileError:
        pass
    if args.manifest and manifest:
        print(manifest.decode("utf-8", "replace"))
    return 0


# --------------------------------------------------------------------------- device transport

FRAME_RE = re.compile(r"\[(\*?\S+) ([0-9A-Fa-f]+) (\d+) (.*?) ([01])\]", re.DOTALL)


class Frame:
    def __init__(self, path, ts, seq, payload, ok, raw):
        self.path, self.ts, self.seq, self.payload, self.ok, self.raw = path, ts, seq, payload, ok, raw

    @property
    def is_event(self):
        return self.path.startswith("*")

    def __repr__(self):
        return f"Frame({self.path!r}, {self.payload!r}, ok={self.ok})"


def parse_frames(text):
    """All complete frames in `text` -> ([Frame], leftover text after the last frame)."""
    frames = []
    end = 0
    for m in FRAME_RE.finditer(text):
        frames.append(Frame(m.group(1), m.group(2), int(m.group(3)), m.group(4), m.group(5) == "1", m.group(0)))
        end = m.end()
    return frames, text[end:]


class WireTimeout(CliError):
    pass


class Wire:
    """The FreeWili menu protocol over a serial-like object (write/read/in_waiting). dry_run prints
    every byte that would be sent and never reads."""

    def __init__(self, ser=None, dry_run=False, log=None):
        self.ser = ser
        self.dry_run = dry_run
        self.log = log or (lambda s: None)
        self.buffer = ""
        self.events = []

    # -- raw
    def write(self, data):
        if self.dry_run:
            print(f"send {data!r}")
            return
        self.log(f">> {data!r}" if len(data) <= 96 else f">> <{len(data)} bytes>")
        self.ser.write(data)

    def _pump(self):
        if self.ser is None:
            return
        n = getattr(self.ser, "in_waiting", 0) or 0
        chunk = self.ser.read(max(n, 1))
        if chunk:
            self.buffer += chunk.decode("utf-8", "replace")

    def _take_frames(self):
        frames, self.buffer = parse_frames(self.buffer)
        keep = []
        for f in frames:
            if f.is_event:
                self.events.append(f)
                self.log(f"<< event {f.raw}")
            else:
                keep.append(f)
        return keep

    def wait_frame(self, predicate, timeout, what="reply"):
        """First non-event frame satisfying predicate(frame) within timeout seconds."""
        deadline = time.monotonic() + timeout
        pending = []
        while True:
            pending += self._take_frames()
            for f in pending:
                self.log(f"<< {f.raw}")
                if predicate(f):
                    return f
            pending = []
            if time.monotonic() >= deadline:
                tail = self.buffer.strip()[-200:]
                raise WireTimeout(f"timeout ({timeout:g}s) waiting for {what}" + (f"; got: {tail!r}" if tail else ""))
            self._pump()

    def reset_menu(self):
        """Ctrl-C returns the device menu to its root; drop anything already buffered."""
        self.write(MENU_RESET)
        if not self.dry_run:
            time.sleep(0.05)
            self._pump()
            self.buffer = ""

    # -- commands
    @staticmethod
    def command_bytes(path, args=""):
        return (path + (" " + args if args else "") + "\n").encode("ascii")

    def command(self, path, args="", timeout=3.0):
        """Send `path args\\n` from the menu root and return the framed reply for that path (None in dry run)."""
        self.reset_menu()
        self.write(self.command_bytes(path, args))
        if self.dry_run:
            return None
        return self.wait_frame(lambda f: f.path == path, timeout, what=f"[{path} ...] reply")

    # -- file get (h\x\u): "[h\x\u ... RxFile N 1]" then N raw bytes then "[h\x\u ... success N bytes CRC crc 1]"
    def get_file(self, devpath, timeout=30.0, progress=None):
        """Download `devpath` from the device. Returns bytes; raises CliError on refusal or CRC mismatch.

        Wire: "[h\\x\\u <ts> <seq> RxFile <size> 1]" + line ending, then <size> raw bytes, then
        "[h\\x\\u <ts> <seq> success <size> bytes <crc32> crc 1]". The raw bytes are read straight
        from the port (the text buffer is bypassed); the file window is located by the completion
        frame and confirmed by its CRC-32, so the line ending after the handshake never
        contaminates the data.
        """
        path = WIRE["file_get"]
        self.reset_menu()
        self.write(self.command_bytes(path, devpath))
        if self.dry_run:
            return b""
        head = self.wait_frame(lambda f: f.path == path, timeout, what="RxFile handshake")
        m = re.search(r"RxFile\s+(\d+)", head.payload or "")
        if not head.ok or not m:
            raise CliError(f"device refused the download: {head.raw}")
        size = int(m.group(1))
        raw = self.buffer.encode("latin-1", "replace")   # bytes already pulled after the frame
        self.buffer = ""
        done_re = re.compile(rb"\[h\\x\\u [0-9A-Fa-f]+ \d+ success (\d+) bytes (\d+) crc (\d)\]")
        deadline = time.monotonic() + timeout + size / 5000.0
        mdone = None
        while True:
            mdone = done_re.search(raw)
            if mdone:
                break
            chunk = self.ser.read(min(65536, max(1, size + 128 - len(raw))))
            if chunk:
                raw += chunk
                if progress:
                    progress(min(len(raw), size), size)
            elif time.monotonic() > deadline:
                raise WireTimeout(f"timeout after {len(raw)} bytes of {devpath} (expected {size})")
        region = raw[:mdone.start()]
        device_crc = int(mdone.group(2))
        self.buffer = raw[mdone.end():].decode("utf-8", "replace")
        # The region is [line ending][size file bytes][optional line ending]; pick the window the CRC confirms.
        for lead in (2, 1, 0, 3, 4):
            cand = region[lead:lead + size]
            if len(cand) == size and (zlib.crc32(cand) & 0xFFFFFFFF) == device_crc:
                return cand
        raise CliError(f"download CRC mismatch for {devpath}: device {device_crc}, region {len(region)} bytes for size {size}")

    # -- file put (h\x\f)
    @staticmethod
    def put_header(devpath, size, crc):
        p = f'"{devpath}"' if QUOTE_PUT_PATH else devpath
        return f"{p} {size} {crc}"

    def put_file(self, data, devpath, stepwise=False, timeout=8.0, progress=None):
        """Upload `data` to `devpath`. Single-line `h\\x\\f <path> <size> <crc>` first, then the stepwise
        form (`h`, `x`, `f`, then the header line) if the device gives no handshake. Returns the completion
        frame payload; raises CliError on refusal or checksum failure."""
        crc = zlib.crc32(data) & 0xFFFFFFFF
        header = self.put_header(devpath, len(data), crc)
        if self.dry_run:
            self.reset_menu()
            if stepwise:
                for step in ("h", "x", "f"):
                    self.write((step + "\n").encode())
                self.write((header + "\n").encode())
            else:
                self.write(self.command_bytes(WIRE["file_put"], header))
            print(f"send <{len(data)} raw bytes> (crc32 0x{crc:08X}); wait for 'Send File Now' then completion frame")
            return "dry run"

        def handshake(f):
            return "Send File Now" in f.payload or "Invalid" in f.payload

        got = None
        if not stepwise:
            self.reset_menu()
            self.write(self.command_bytes(WIRE["file_put"], header))
            try:
                got = self.wait_frame(handshake, timeout, what="'Send File Now'")
            except WireTimeout as exc:
                self.log(f"single-line put got no handshake ({exc}); falling back to stepwise")
        if got is None:
            self.reset_menu()
            for step in ("h", "x", "f"):
                self.write((step + "\n").encode())
                time.sleep(0.02)
            self.write((header + "\n").encode())
            got = self.wait_frame(handshake, timeout, what="'Send File Now' (stepwise)")
        if "Invalid" in got.payload or not got.ok:
            raise CliError(f"device refused the file header {header!r}: {got.raw}")
        sent = 0
        for off in range(0, len(data), PUT_CHUNK):
            chunk = data[off:off + PUT_CHUNK]
            self.write(chunk)
            sent += len(chunk)
            if progress:
                progress(sent, len(data))
        done = self.wait_frame(lambda f: "success" in f.payload or "Failed" in f.payload or "fail" in f.payload.lower(),
                               max(timeout, 20.0), what="file completion frame")
        if not done.ok or "success" not in done.payload:
            raise CliError(f"file transfer failed: {done.raw}")
        return done.payload


def find_main_port():
    try:
        from serial.tools import list_ports
    except ImportError as exc:
        raise CliError("pyserial is required for device commands (pip install pyserial)") from exc
    hits = [p.device for p in list_ports.comports() if p.vid == MAIN_VID and p.pid == MAIN_PID]
    if not hits:
        raise CliError(f"no FreeWili 2 MAIN port found (USB VID 0x{MAIN_VID:04X} PID 0x{MAIN_PID:04X}); use --port")
    if len(hits) > 1:
        print(f"note: several MAIN ports {hits}; using {hits[0]} (override with --port)", file=sys.stderr)
    return hits[0]


def open_wire(args):
    if args.print:
        return Wire(dry_run=True)
    import serial
    port = args.port or find_main_port()
    ser = serial.Serial(port, BAUD, timeout=0.1, write_timeout=10)
    log = (lambda s: print(s, file=sys.stderr)) if args.verbose else None
    return Wire(ser, log=log)


def close_wire(wire):
    if wire.ser is not None:
        try:
            wire.ser.close()
        except Exception:
            pass


# --------------------------------------------------------------------------- device commands

def device_path_for(repo, target):
    """design name | local .fwfpga path | /device/path -> the path on the device's SD card."""
    if target.startswith("/"):
        return target
    name = Path(target).name
    if name.endswith(".fwfpga"):
        name = name[:-len(".fwfpga")]
    return f"{DEVICE_FPGA_DIR}/{name}.fwfpga"


def resolve_container(repo, target):
    p = Path(target)
    if p.is_file():
        return p
    built = repo.build / target / f"{target}.fwfpga"
    if built.is_file():
        return built
    raise CliError(f"{target} is neither a .fwfpga file nor a built design (expected {repo.rel(built)}); run `fwfpga build {target}`")


def cmd_install(args, repo):
    path = resolve_container(repo, args.target)
    header, errors, notes = check_container.check_file(path, args.design, args.allow_size, repo.designs)
    for n in notes:
        print(f"note: {n}")
    if errors:
        for e in errors:
            print(f"FAIL: {e}", file=sys.stderr)
        raise CliError(f"refusing to install {path}: not a valid .fwfpga container")
    dest = args.dest or f"{DEVICE_FPGA_DIR}/{header.name}.fwfpga"
    data = path.read_bytes()
    print(f"install {repo.rel(path)} ({len(data)} bytes) -> {dest}   [{iop.summary(iop.unpack(header.io_profile))}]")
    wire = open_wire(args)
    try:
        def progress(sent, total):
            if sent == total or sent % (16 * PUT_CHUNK) == 0:
                print(f"  {sent}/{total}", end="\r" if sent != total else "\n", flush=True)
        result = wire.put_file(data, dest, stepwise=args.stepwise, progress=progress)
    finally:
        close_wire(wire)
    print(f"device: {result}")
    return 0


def _simple_device_command(args, path, wire_args="", timeout=5.0, parse=None):
    wire = open_wire(args)
    try:
        frame = wire.command(path, wire_args, timeout=timeout)
    finally:
        close_wire(wire)
    if frame is None:
        return 0
    print(frame.payload if parse is None else parse(frame))
    if not frame.ok:
        print(f"device reported failure: {frame.raw}", file=sys.stderr)
        return 1
    return 0


def parse_load_reply(frame):
    """`id version cdone ms` -> readable line; anything else is echoed."""
    toks = frame.payload.split()
    if len(toks) >= 4 and all(t.lstrip("-").isdigit() or t.lower().startswith("0x") for t in toks[:4]):
        return (f"design_id {toks[0]}  version {toks[1]}  cdone {toks[2]}  load_ms {toks[3]}"
                + (" " + " ".join(toks[4:]) if len(toks) > 4 else ""))
    return frame.payload


def cmd_load(args, repo):
    devpath = device_path_for(repo, args.target)
    return _simple_device_command(args, WIRE["load"], f'"{devpath}"', timeout=args.timeout, parse=parse_load_reply)


def cmd_restore(args, repo):
    return _simple_device_command(args, WIRE["restore"], timeout=args.timeout)


def cmd_status(args, repo):
    return _simple_device_command(args, WIRE["status"], parse=format_status)


STATUS_FIELDS = ("source", "armed", "cdone", "id", "version", "caps", "clock_hz", "profile", "name", "load_ms", "error")


def parse_status(payload):
    """`source armed cdone id version caps clock_hz profile name load_ms error [contention]` -> dict, or None.
    Example: `stock 0 1 0 0 00 31245000 00000000 - 0 - -`. caps and profile are hex without 0x.
    `contention` (firmware F3b and later) is '-' when the self-checks are clean, else
    rp:<signal>, fabric:<signal> or prearm:<signal>; older firmware omits it."""
    toks = payload.split()
    if len(toks) < len(STATUS_FIELDS):
        return None
    d = dict(zip(STATUS_FIELDS, toks))
    d["contention"] = toks[len(STATUS_FIELDS)] if len(toks) > len(STATUS_FIELDS) else None
    return d


def format_status(frame):
    """Pretty-print the h\\f\\s payload with the profile decoded; echo it raw if the shape is unknown."""
    st = parse_status(frame.payload)
    if st is None:
        return frame.payload
    lines = [frame.payload, ""]
    try:
        caps = int(st["caps"], 16)
        caps_text = ", ".join(design_toml.caps_from_byte(caps)) or "(none)"
    except (ValueError, design_toml.DesignError):
        caps_text = st["caps"]
    lines.append(f"source   {st['source']}   armed {st['armed']}   cdone {st['cdone']}")
    lines.append(f"design   id {st['id']}  version {st['version']}  name {st['name']}  caps {st['caps']} ({caps_text})")
    lines.append(f"clock    {st['clock_hz']} Hz   load {st['load_ms']} ms   error {st['error']}")
    if st.get("contention") is not None:
        verdict = "clean" if st["contention"] == "-" else f"FOUND {st['contention']}"
        lines.append(f"contention self-checks: {verdict}")
    try:
        prof = iop.unpack(int(st["profile"], 16))
        lines.append(f"profile  {st['profile']}: {iop.summary(prof)}")
        lines.append(iop.table_text(prof))
    except (ValueError, iop.ProfileError) as exc:
        lines.append(f"profile  {st['profile']} (undecodable: {exc})")
    return "\n".join(lines)


def _int_arg(text, what, maximum):
    try:
        v = int(text, 0)
    except ValueError:
        raise CliError(f"{what} must be an integer (decimal or 0x hex), got {text!r}")
    if not 0 <= v <= maximum:
        raise CliError(f"{what} {text} out of range 0..0x{maximum:X}")
    return v


def reg_bytes_arg(values):
    """`reg w` payload: one or more byte values (decimal or 0x hex) or one even-length hex string
    ("80", "8001"). Returned as typed, joined by spaces, after validation."""
    if not values:
        raise CliError("reg w needs <addr> <bytes>")
    for v in values:
        if re.fullmatch(r"[0-9A-Fa-f]+", v) and len(v) % 2 == 0 and not v.isdigit():
            continue                                # bare hex string such as 80AB
        if re.fullmatch(r"[0-9A-Fa-f]{2}", v) and not v.isdigit():
            continue
        _int_arg(v, "register byte", 0xFF)
    return " ".join(values)


def cmd_reg(args, repo):
    # The firmware parses the address with parseHex() and the data with
    # parseBytes(): bare hex tokens, no 0x prefix (hardware-confirmed
    # 2026-10-31: "0x03" is rejected as Invalid). Accept anything the user
    # types and normalise on the wire.
    addr = _int_arg(args.addr, "register address", 0x7F)
    if args.op == "r":
        count = args.values[0] if args.values else "1"
        if len(args.values) > 1:
            raise CliError("reg r takes <addr> [count]")
        n = _int_arg(count, "count", 0xFFFF)
        return _simple_device_command(args, WIRE["reg_r"], f"{addr:02X} {n}")
    if not args.values:
        raise CliError("reg w needs <addr> <byte> [byte ...]")
    data = []
    for tok in args.values:
        t = tok.strip()
        if re.fullmatch(r"(0[xX])?[0-9A-Fa-f]{2}([0-9A-Fa-f]{2})+", t):   # a run of hex bytes, e.g. 80AB or 0x80AB
            data += list(bytes.fromhex(t[2:] if t[:2].lower() == "0x" else t))
        elif re.fullmatch(r"[0-9A-Fa-f]{2}", t) and re.search(r"[A-Fa-f]", t):   # bare 2-digit hex with a letter, e.g. FF
            data.append(int(t, 16))
        else:
            data.append(_int_arg(t, "data byte", 0xFF))
    return _simple_device_command(args, WIRE["reg_w"], f"{addr:02X} " + " ".join(f"{b:02X}" for b in data))


def cmd_stream_pio(args, repo):
    """T2: h\\f\\p <n> <path> captures the PIO link (GPIO8-15 sampled on GPIO26) into a device
    file in 32 KB SRAM bursts at the full link rate, then fetch it. With --check the bytes are
    verified as a consecutive 8-bit counter inside every burst (the pio_link design's pattern)."""
    if getattr(args, "continuous", False):
        return cmd_stream_pio_continuous(args, repo)
    n = _int_arg(args.count, "count", 4194304)
    wire = open_wire(args)
    try:
        frame = wire.command(WIRE["pio_capture"], f"{n} {PIO_CAPTURE_DEVPATH}", timeout=max(10.0, n / 20000.0))
        if frame is not None and not frame.ok:
            raise CliError(f"device reported failure: {frame.raw}")
        if frame is None:
            return 0
        parts = frame.payload.split()
        ms = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None
        rate = f"{n / ms / 1000.0:.1f} MB/s" if ms else "n/a"
        print(f"captured {parts[0] if parts else '?'} bytes in {ms} ms of link time = {rate} (bursts of {PIO_BURST_BYTES})")
        data = wire.get_file(PIO_CAPTURE_DEVPATH, timeout=60.0)
    finally:
        close_wire(wire)
    if args.out:
        Path(args.out).write_bytes(data)
        print(f"wrote {len(data)} bytes to {args.out}")
    if getattr(args, "check", False):
        bad = [i for i in range(len(data) - 1)
               if (data[i + 1] - data[i]) % 256 != 1 and (i + 1) % PIO_BURST_BYTES != 0]
        bursts = (len(data) + PIO_BURST_BYTES - 1) // PIO_BURST_BYTES
        if bad:
            raise CliError(f"counter pattern broken at {len(bad)} places inside {bursts} bursts, first at {bad[:5]}")
        print(f"pattern ok: consecutive 8-bit counter inside all {bursts} bursts")
    elif not args.out:
        for off in range(0, min(len(data), 256), 16):
            print(f"{off:06x}  {data[off:off + 16].hex(' ')}")
    return 0


def _link_div(args):
    return _int_arg(str(getattr(args, "div", None) or 2), "PIO clock divider", 255) or 2


def cmd_stream_pio_continuous(args, repo):
    """h\\f\\k <n> <path> <div> with an RP2350-clocked capture design (pio_stream): the RP2350
    PIO drives the link clock and stalls it whenever its buffers are full, so the file is one
    unbroken, lossless stream. --check verifies the counter across the WHOLE file."""
    n = _int_arg(args.count, "count", 64 * 1024 * 1024)
    div = _link_div(args)
    wire = open_wire(args)
    try:
        frame = wire.command(WIRE["link_stream"], f"{n} {PIO_CAPTURE_DEVPATH} {div}", timeout=max(15.0, n / 200000.0))
        if frame is None:
            return 0
        if not frame.ok:
            raise CliError(f"device reported failure: {frame.raw}")
        parts = frame.payload.split()
        ms = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None
        rate = f"{n / ms / 1000.0:.2f} MB/s" if ms else "n/a"
        print(f"captured {parts[0] if parts else '?'} bytes continuously in {ms} ms incl. SD writes = {rate} (PIO div {div})")
        data = wire.get_file(PIO_CAPTURE_DEVPATH, timeout=120.0)
    finally:
        close_wire(wire)
    if args.out:
        Path(args.out).write_bytes(data)
        print(f"wrote {len(data)} bytes to {args.out}")
    if getattr(args, "check", False):
        bad = [i for i in range(len(data) - 1) if (data[i + 1] - data[i]) % 256 != 1]
        if bad or len(data) != n:
            raise CliError(f"continuous counter broken at {len(bad)} places (first {bad[:5]}), {len(data)} of {n} bytes")
        print(f"pattern ok: one unbroken 8-bit counter across all {len(data)} bytes")
    elif not args.out:
        for off in range(0, min(len(data), 256), 16):
            print(f"{off:06x}  {data[off:off + 16].hex(' ')}")
    return 0


def cmd_stream_tx(args, repo):
    """h\\f\\k <n> - <div> with an RP2350->FPGA design (pio_sink): the PIO clocks a repeating
    00..FF counter into the FPGA. --check clears and then reads pio_sink's byte and error
    counters (registers 0x10, 0x11-0x18) and fails unless every byte arrived intact."""
    n = _int_arg(args.count, "count", 64 * 1024 * 1024) & ~3
    div = _link_div(args)
    wire = open_wire(args)
    try:
        if getattr(args, "check", False):
            wire.command(WIRE["reg_w"], "10 01")
        frame = wire.command(WIRE["link_stream"], f"{n} - {div}", timeout=max(15.0, n / 200000.0))
        if frame is None:
            return 0
        if not frame.ok:
            raise CliError(f"device reported failure: {frame.raw}")
        parts = frame.payload.split()
        ms = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None
        rate = f"{n / ms / 1000.0:.2f} MB/s" if ms else "n/a"
        print(f"sent {n} bytes in {ms} ms = {rate} (PIO div {div})")
        if getattr(args, "check", False):
            r = wire.command(WIRE["reg_r"], "11 8")
            vals = bytes(int(t, 16) for t in r.payload.split()[:8])
            count, errors = int.from_bytes(vals[0:4], "little"), int.from_bytes(vals[4:8], "little")
            print(f"FPGA (pio_sink): {count} bytes received, {errors} pattern errors")
            if count != n or errors:
                raise CliError("link check failed")
            print("pattern ok: every byte arrived in order")
    finally:
        close_wire(wire)
    return 0


def cmd_get(args, repo):
    """Fetch a file from the device (binary, CRC-checked)."""
    wire = open_wire(args)
    try:
        data = wire.get_file(args.devpath.replace("/", "\\"), timeout=30.0)
    finally:
        close_wire(wire)
    if args.print:
        return 0
    out = Path(args.out) if args.out else Path(Path(args.devpath).name)
    out.write_bytes(data)
    print(f"wrote {len(data)} bytes to {out}")
    return 0


def cmd_stream(args, repo):
    if args.direction == "pio":
        return cmd_stream_pio(args, repo)
    if args.direction == "tx":
        return cmd_stream_tx(args, repo)
    if args.direction != "rx":
        raise CliError("stream directions: rx, pio, tx")
    n = _int_arg(args.count, "count", 1048576)
    wire = open_wire(args)
    try:
        if n > 256:
            # Binary transport: the firmware pulls the FIFO into a file on the SD card
            # (h\f\c count path) and we fetch it back (h\x\u). The console hex path
            # (h\f\x) is capped at 256 bytes per call.
            devpath = CAPTURE_DEVPATH
            frame = wire.command(WIRE["capture"], f"{n} {devpath}", timeout=max(10.0, n / 2000.0))
            if frame is not None and not frame.ok:
                raise CliError(f"device reported failure: {frame.raw}")
            if frame is not None:
                print(f"captured: {frame.payload.strip()} (bytes ms)")
            data = wire.get_file(devpath, timeout=30.0)
            if args.out:
                Path(args.out).write_bytes(data)
                print(f"wrote {len(data)} bytes to {args.out}")
            else:
                for off in range(0, min(len(data), 512), 16):
                    print(f"{off:06x}  {data[off:off + 16].hex(' ')}")
                if len(data) > 512:
                    print(f"... {len(data)} bytes total (use -o FILE to keep them)")
            return 0
        frame = wire.command(WIRE["stream_rx"], str(n), timeout=max(5.0, n / 20000.0))
    finally:
        close_wire(wire)
    if frame is None:
        return 0
    if not frame.ok:
        raise CliError(f"device reported failure: {frame.raw}")
    payload = frame.payload.strip()
    if payload.startswith("/"):
        print(f"device wrote {payload}; fetch it with the file get command (h\\x\\u)")
        return 0
    hexstr = re.sub(r"[^0-9A-Fa-f]", "", payload)
    try:
        data = bytes.fromhex(hexstr)
    except ValueError:
        print(payload)
        return 0
    if args.out:
        Path(args.out).write_bytes(data)
        print(f"wrote {len(data)} bytes to {args.out}")
    else:
        for off in range(0, len(data), 16):
            print(f"{off:06x}  {data[off:off + 16].hex(' ')}")
    return 0


# --------------------------------------------------------------------------- test

def cmd_test(args, repo):
    dirs = [d for d in (repo.root / "tools" / "tests", repo.root / "tests") if d.is_dir()]
    cmd = [sys.executable, "-m", "pytest", "-q"] + [str(d) for d in dirs] + (args.pytest_args or [])
    runner = Runner(repo, args.print)
    r = runner.run(cmd, check=False)
    rc = r.returncode
    if not args.no_sim and (args.print or tool_path("iverilog") is not None):
        targets = [SHELL_TB] if (repo.sim / "tb_shell.v").is_file() else []
        if repo.designs.is_dir():
            targets += [d.name for d in sorted(repo.designs.iterdir()) if repo.tb_sources(d)]
        for name in targets:
            try:
                cmd_sim(argparse.Namespace(design=name, print=args.print), repo)
            except CliError as exc:
                print(f"sim {name}: {exc}", file=sys.stderr)
                rc = rc or 1
    return rc


# --------------------------------------------------------------------------- argparse

def build_parser():
    p = argparse.ArgumentParser(prog="fwfpga", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--print", action="store_true", help="dry run: print every command / byte, run nothing")
    p.add_argument("--port", help="serial port of MAIN (default: auto-detect by USB VID/PID)")
    p.add_argument("--repo", default=str(HERE.parent), help=argparse.SUPPRESS)
    p.add_argument("-v", "--verbose", action="store_true", help="log device traffic to stderr")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("toolchain", help="check or install the pinned oss-cad-suite")
    s.add_argument("action", choices=["check", "install"])
    s.add_argument("--force", action="store_true", help="reinstall even if present")
    s.add_argument("--sha256", help="expected archive digest (printed after download either way)")
    s.add_argument("--keep-archive", action="store_true")
    s.set_defaults(fn=lambda a, r: cmd_toolchain(a))

    s = sub.add_parser("new-design", help="scaffold designs/<name> from designs/template")
    s.add_argument("name")
    s.set_defaults(fn=cmd_new_design)

    s = sub.add_parser("build", help="synth + place/route + timing + pack")
    s.add_argument("design")
    s.add_argument("--freq", type=float, help="nextpnr --freq in MHz (default: design.toml clock_hz)")
    s.set_defaults(fn=cmd_build)

    s = sub.add_parser("lint", help="verilator --lint-only -Wall")
    s.add_argument("design")
    s.set_defaults(fn=cmd_lint)

    s = sub.add_parser("sim", help="iverilog + vvp over designs/<name>/tb/; `sim shell` runs fpga/sim/tb_shell.v")
    s.add_argument("design")
    s.set_defaults(fn=cmd_sim)

    s = sub.add_parser("inspect", help="print a .fwfpga header")
    s.add_argument("file")
    s.add_argument("--manifest", action="store_true")
    s.set_defaults(fn=cmd_inspect)

    s = sub.add_parser("install", help="check_container then file put to /fpga/<name>.fwfpga")
    s.add_argument("target", help="design name (uses build/designs/<name>/<name>.fwfpga) or a .fwfpga path")
    s.add_argument("--dest", help="device path (default /fpga/<header name>.fwfpga)")
    s.add_argument("--design", help="design.toml to compare the header against (default: designs/<name>/)")
    s.add_argument("--stepwise", action="store_true", help="use the h, x, f stepwise form directly")
    s.add_argument("--allow-size", action="store_true", help=argparse.SUPPRESS)
    s.set_defaults(fn=cmd_install)

    s = sub.add_parser("load", help="h\\f\\l: program the FPGA from a container on the SD card")
    s.add_argument("target", help="design name, .fwfpga file name, or /device/path")
    s.add_argument("--timeout", type=float, default=20.0)
    s.set_defaults(fn=cmd_load)

    s = sub.add_parser("restore", help="h\\f\\t: back to the stock gateware")
    s.add_argument("--timeout", type=float, default=20.0)
    s.set_defaults(fn=cmd_restore)

    s = sub.add_parser("status", help="h\\f\\s: source armed cdone id version caps clock_hz profile name load_ms error")
    s.set_defaults(fn=cmd_status)

    s = sub.add_parser("reg", help="reg r <addr> [count] -> h\\f\\r <addr> <count>;  reg w <addr> <bytes> -> h\\f\\w <addr> <bytes>")
    s.add_argument("op", choices=["r", "w"])
    s.add_argument("addr")
    s.add_argument("values", nargs="*", help="r: count (default 1); w: byte values or a hex string")
    s.set_defaults(fn=cmd_reg)

    s = sub.add_parser("stream", help="h\\f\\x <n>: burst-read n bytes from the stream FIFO")
    s.add_argument("direction", choices=["rx", "pio", "tx"],
                   help="rx = register-bus FIFO; pio = parallel link FPGA->RP2350 (h\\f\\p bursts, or h\\f\\k with --continuous); "
                        "tx = parallel link RP2350->FPGA (h\\f\\k)")
    s.add_argument("count")
    s.add_argument("-o", "--out", help="write the bytes to a file instead of a hex dump")
    s.add_argument("--check", action="store_true",
                   help="pio: verify the counter pattern (inside every burst, or across the whole file with --continuous); "
                        "tx: read pio_sink's byte/error counters")
    s.add_argument("--continuous", action="store_true",
                   help="pio: RP2350-clocked lossless stream (pio_stream design) instead of 32 KB bursts")
    s.add_argument("--div", help="PIO clock divider for --continuous / tx (1 = fastest, default 2)")
    s.set_defaults(fn=cmd_stream)

    s = sub.add_parser("get", help="fetch a file from the device (binary, CRC-checked)")
    s.add_argument("devpath", help="device path, e.g. /fpga/cap.bin")
    s.add_argument("-o", "--out", help="local file (default: the device file name)")
    s.set_defaults(fn=cmd_get)

    s = sub.add_parser("test", help="pytest over tools/tests and tests/ (+ sims when the toolchain is present)")
    s.add_argument("--no-sim", action="store_true")
    s.add_argument("pytest_args", nargs=argparse.REMAINDER)
    s.set_defaults(fn=cmd_test)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    repo = Repo(args.repo)
    try:
        return args.fn(args, repo) or 0
    except CliError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except (design_toml.DesignError, ff.FormatError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
