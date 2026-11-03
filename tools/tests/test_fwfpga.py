"""CLI tests: dry runs over a fixture repo, report parsing, and the device transport against a fake serial."""
import json
import os
import re
import stat
import zlib
from pathlib import Path

import pytest

import fwfpga as fw
import fwfpga_format as ff
import pack_fwfpga as pk
import design_toml as dt
import tomllib
from conftest import GOOD_TOML, STOCK_TOML, fake_bitstream


# --------------------------------------------------------------------------- fixture repo

TEMPLATE_TOML = GOOD_TOML.replace('name = "hello_blink"', 'name = "template"').replace("design_id = 1", "design_id = 0")


@pytest.fixture
def repo(tmp_path):
    root = tmp_path / "repo"
    (root / "fpga" / "shell").mkdir(parents=True)
    (root / "fpga" / "lib" / "io_buffer").mkdir(parents=True)
    (root / "fpga" / "sim").mkdir()
    (root / "fpga" / "constraints").mkdir()
    (root / "fpga" / "shell" / "fw2_shell.v").write_text("module fw2_shell; endmodule\n")
    (root / "fpga" / "shell" / "fw2_user_core.vh").write_text("")
    (root / "fpga" / "lib" / "io_buffer" / "io_buffer.v").write_text("module io_buffer; endmodule\n")
    (root / "fpga" / "sim" / "spi_bus_bfm.v").write_text("module spi_bus_bfm; endmodule\n")
    (root / "fpga" / "sim" / "tb_shell.v").write_text("module tb_shell; endmodule\n")
    (root / "fpga" / "constraints" / "fw2.pcf").write_text("set_io CLK 37\nset_io GPIO_26_Out 36\n")
    for name, toml in (("hello_blink", GOOD_TOML), ("template", TEMPLATE_TOML)):
        d = root / "designs" / name
        (d / "tb").mkdir(parents=True)
        (d / "host").mkdir()
        (d / "design.toml").write_text(toml)
        (d / "user_core.v").write_text(f"module user_core; // {name}\nendmodule\n")
        (d / "tb" / f"tb_{name}.v").write_text(f"module tb_{name}; initial $finish; endmodule\n")
        (d / "README.md").write_text(f"# {name}\n")
    s = root / "designs" / "stock_example"
    s.mkdir()
    (s / "design.toml").write_text(STOCK_TOML.replace(
        'repository = "https://github.com/freewili/wilifpga"',
        'repository = "wilifpga"\ntop = "main"\nsources = ["main.v", "stock_top.v"]\ninclude_dirs = ["fpga/lib/ext_ctrl"]'))
    (s / "main.v").write_text("module main(input CLK, output GPIO_26_Out); endmodule\n")
    (s / "stock_top.v").write_text("module stock_top; endmodule\n")
    (s / "unused.v").write_text("module unused; endmodule\n")
    (root / "fpga" / "lib" / "ext_ctrl").mkdir()
    (root / "fpga" / "lib" / "ext_ctrl" / "ext_defs.vh").write_text("")
    (root / "fpga" / "lib" / "ext_ctrl" / "ext_ctrl.v").write_text("module ext_ctrl; endmodule\n")
    (root / "fpga" / "lib" / "fw2_stream_fifo").mkdir()
    (root / "fpga" / "lib" / "fw2_stream_fifo" / "fw2_stream_fifo.v").write_text("module fw2_stream_fifo; endmodule\n")
    (root / "fpga" / "sim" / "tb_design").mkdir()
    (root / "fpga" / "sim" / "tb_design" / "user_core.v").write_text("module user_core; endmodule\n")
    (root / "fpga" / "sim" / "tb_design" / "fw2_design_id.vh").write_text("")
    return fw.Repo(root)


def run_cli(repo, *argv, capsys=None):
    rc = fw.main(["--repo", str(repo.root)] + list(argv))
    out = capsys.readouterr() if capsys else None
    return rc, out


# --------------------------------------------------------------------------- toolchain

def test_toolchain_dir_env_override(tmp_path, monkeypatch):
    suite = tmp_path / "suite"
    (suite / "bin").mkdir(parents=True)
    monkeypatch.setenv("OSS_CAD_SUITE", str(suite))
    assert fw.oss_cad_suite_dir() == suite
    monkeypatch.setenv("OSS_CAD_SUITE", str(suite / "bin"))
    assert fw.oss_cad_suite_dir() == suite
    monkeypatch.setenv("OSS_CAD_SUITE", str(suite))
    monkeypatch.delenv("VERILATOR_ROOT", raising=False)
    env = fw.tool_env()
    assert env["PATH"].startswith(str(suite / "bin") + os.pathsep + str(suite / "lib"))
    assert "VERILATOR_ROOT" not in env
    (suite / "share" / "verilator" / "include").mkdir(parents=True)
    (suite / "share" / "verilator" / "include" / "verilated_std.sv").write_text("")
    assert fw.tool_env()["VERILATOR_ROOT"] == str(suite / "share" / "verilator")
    monkeypatch.setenv("OSS_CAD_SUITE", str(tmp_path / "nope"))
    assert fw.oss_cad_suite_dir() is None


def test_pinned_install_location(tmp_path, monkeypatch):
    monkeypatch.delenv("OSS_CAD_SUITE", raising=False)
    monkeypatch.setattr(fw, "OSS_CAD_SUITE_ROOT", tmp_path)
    assert fw.oss_cad_suite_dir() is None
    pinned = tmp_path / fw.OSS_CAD_SUITE_RELEASE / "oss-cad-suite" / "bin"
    pinned.mkdir(parents=True)
    assert fw.oss_cad_suite_dir() == pinned.parent
    assert fw.OSS_CAD_SUITE_RELEASE == "2026-10-31"


def test_archive_names():
    assert fw.toolchain_archive_name("2026-10-31", "Windows", "AMD64") == "oss-cad-suite-windows-x64-20261031.tgz"
    assert fw.toolchain_archive_name("2026-10-31", "Linux", "x86_64") == "oss-cad-suite-linux-x64-20261031.tgz"
    assert fw.toolchain_archive_name("2026-10-31", "Darwin", "arm64") == "oss-cad-suite-darwin-arm64-20261031.tgz"
    with pytest.raises(fw.CliError):
        fw.toolchain_archive_name("2026-10-31", "Plan9", "x")


def test_toolchain_check_reports_missing(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("OSS_CAD_SUITE", str(tmp_path / "empty"))
    monkeypatch.setenv("PATH", str(tmp_path))
    monkeypatch.setattr(fw, "OSS_CAD_SUITE_ROOT", tmp_path)
    rc = fw.main(["toolchain", "check"])
    out = capsys.readouterr().out
    assert rc == 1 and "MISSING" in out and "yosys" in out


def test_toolchain_install_print(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(fw, "OSS_CAD_SUITE_ROOT", tmp_path)
    rc = fw.main(["--print", "toolchain", "install"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-10-31/oss-cad-suite-" in out
    assert "20261031.tgz" in out


def test_toolchain_install_skips_when_present(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(fw, "OSS_CAD_SUITE_ROOT", tmp_path)
    (tmp_path / fw.OSS_CAD_SUITE_RELEASE / "oss-cad-suite" / "bin").mkdir(parents=True)
    assert fw.main(["toolchain", "install"]) == 0
    assert "already installed" in capsys.readouterr().out


# --------------------------------------------------------------------------- build / lint / sim dry runs

def test_build_print_user_design(repo, capsys, monkeypatch):
    monkeypatch.setenv("OSS_CAD_SUITE", str(repo.root / "nosuite"))
    rc, out = run_cli(repo, "--print", "build", "hello_blink", capsys=capsys)
    assert rc == 0, out.err
    lines = out.out.splitlines()
    ys = next(l for l in lines if l.startswith("yosys"))
    assert "synth_ice40 -top fw2_shell -json build/designs/hello_blink/hello_blink.json" in ys
    assert ("read_verilog -Ifpga/shell -Ibuild/designs/hello_blink -Ifpga/lib/ext_ctrl "
            "fpga/shell/fw2_shell.v fpga/lib/ext_ctrl/ext_ctrl.v fpga/lib/fw2_stream_fifo/fw2_stream_fifo.v "
            "fpga/lib/io_buffer/io_buffer.v designs/hello_blink/user_core.v;") in ys
    pnr = next(l for l in lines if l.startswith("nextpnr-ice40"))
    assert "--up5k --package sg48 --pcf fpga/constraints/fw2.pcf" in pnr
    assert "--json build/designs/hello_blink/hello_blink.json --asc build/designs/hello_blink/hello_blink.asc" in pnr
    assert "--freq 31.25 --report build/designs/hello_blink/report.json" in pnr
    assert any(l.startswith("icepack build/designs/hello_blink/hello_blink.asc build/designs/hello_blink/hello_blink.bin") for l in lines)
    assert any("hello_blink.fwfpga" in l for l in lines)
    assert not (repo.build / "hello_blink").exists()   # dry run writes nothing


def test_build_print_freq_override_and_stock_top(repo, capsys, monkeypatch):
    monkeypatch.setenv("OSS_CAD_SUITE", str(repo.root / "nosuite"))
    rc, out = run_cli(repo, "--print", "build", "stock_example", "--freq", "48", capsys=capsys)
    assert rc == 0, out.err
    ys = next(l for l in out.out.splitlines() if l.startswith("yosys"))
    assert "-top main" in ys and "fw2_shell.v" not in ys
    # design.toml `sources` (in order, nothing else from the folder), lib minus fw2_*, extra include dir once
    assert "designs/stock_example/main.v designs/stock_example/stock_top.v;" in ys
    assert "unused.v" not in ys and "fw2_stream_fifo" not in ys and "fpga/lib/io_buffer/io_buffer.v" in ys
    assert ys.count("-Ifpga/lib/ext_ctrl") == 1
    assert "--freq 48 " in out.out


def test_sources_entry_must_exist(repo, capsys):
    toml = (repo.designs / "stock_example" / "design.toml").read_text()
    (repo.designs / "stock_example" / "design.toml").write_text(toml.replace('"stock_top.v"', '"missing.v"'))
    rc, out = run_cli(repo, "--print", "build", "stock_example", capsys=capsys)
    assert rc == 1 and "missing.v" in out.err


def test_sim_shell(repo, capsys, monkeypatch):
    monkeypatch.setenv("OSS_CAD_SUITE", str(repo.root / "nosuite"))
    rc, out = run_cli(repo, "--print", "sim", "shell", capsys=capsys)
    assert rc == 0, out.err
    iv = next(l for l in out.out.splitlines() if l.startswith("iverilog"))
    assert "-I fpga/sim -Ifpga/shell -Ifpga/sim/tb_design -Ifpga/lib/ext_ctrl -o build/sim/sim.vvp fpga/sim/tb_shell.v fpga/sim/spi_bus_bfm.v fpga/shell/fw2_shell.v" in iv
    assert "fpga/sim/tb_design/user_core.v <suite>/share/yosys/ice40/cells_sim.v" in iv
    rc, out = run_cli(repo, "--print", "test", capsys=capsys)
    assert rc == 0 and out.out.count("iverilog") == 3     # shell, hello_blink, template


def test_build_refuses_failing_check_design(repo, capsys):
    (repo.designs / "hello_blink" / "user_core.v").write_text("module user_core(output GPIO_26_Out); endmodule\n")
    rc, out = run_cli(repo, "--print", "build", "hello_blink", capsys=capsys)
    assert rc == 1 and "GPIO_26_Out" in out.err and "check_design failed" in out.err


def test_build_unknown_design(repo, capsys):
    rc, out = run_cli(repo, "--print", "build", "nope", capsys=capsys)
    assert rc == 1 and "no such design" in out.err


def test_lint_and_sim_print(repo, capsys, monkeypatch):
    monkeypatch.setenv("OSS_CAD_SUITE", str(repo.root / "nosuite"))
    rc, out = run_cli(repo, "--print", "lint", "hello_blink", capsys=capsys)
    assert rc == 0
    assert "--lint-only -Wall --top-module fw2_shell -Ifpga/shell -Ibuild/designs/hello_blink" in out.out
    rc, out = run_cli(repo, "--print", "sim", "hello_blink", capsys=capsys)
    assert rc == 0, out.err
    iv = next(l for l in out.out.splitlines() if l.startswith("iverilog"))
    assert "-g2012 -I fpga/sim -Ifpga/shell -Ibuild/designs/hello_blink -Ifpga/lib/ext_ctrl -o build/designs/hello_blink/sim.vvp" in iv
    assert "designs/hello_blink/tb/tb_hello_blink.v fpga/sim/spi_bus_bfm.v fpga/shell/fw2_shell.v" in iv
    assert "tb_shell.v" not in iv
    assert iv.endswith("<suite>/share/yosys/ice40/cells_sim.v")     # no suite in this test env
    assert any(l.startswith("vvp -N build/designs/hello_blink/sim.vvp") for l in out.out.splitlines())


def test_sim_uses_suite_cell_models_and_lint_uses_waivers(repo, tmp_path, capsys, monkeypatch):
    suite = tmp_path / "suite"
    cells = suite / "share" / "yosys" / "ice40" / "cells_sim.v"
    cells.parent.mkdir(parents=True)
    cells.write_text("module SB_SPRAM256KA; endmodule\n")
    (suite / "bin").mkdir()
    monkeypatch.setenv("OSS_CAD_SUITE", str(suite))
    monkeypatch.delenv("ICE40_CELLS_SIM", raising=False)
    assert fw.ice40_cells_sim() == cells
    rc, out = run_cli(repo, "--print", "sim", "hello_blink", capsys=capsys)
    assert rc == 0 and out.out.splitlines()[0].endswith(str(cells)) or str(cells) in out.out
    monkeypatch.setenv("ICE40_CELLS_SIM", str(tmp_path / "mine.v"))
    assert fw.ice40_cells_sim() == tmp_path / "mine.v"

    rc, out = run_cli(repo, "--print", "lint", "hello_blink", capsys=capsys)
    assert "lint.vlt" not in out.out
    (repo.fpga / "lint.vlt").write_text("`verilator_config\nlint_off -rule PROCASSINIT -file \"*/fpga/lib/*\"\n")
    rc, out = run_cli(repo, "--print", "lint", "hello_blink", capsys=capsys)
    assert rc == 0 and "-Ifpga/lib/ext_ctrl fpga/lint.vlt fpga/shell/fw2_shell.v" in out.out


def test_sim_without_tb(repo, capsys):
    import shutil
    shutil.rmtree(repo.designs / "hello_blink" / "tb")
    rc, out = run_cli(repo, "--print", "sim", "hello_blink", capsys=capsys)
    assert rc == 1 and "no testbench" in out.err


# --------------------------------------------------------------------------- report parsing

REPORT = {
    "fmax": {"CLK$SB_IO_IN_$glb_clk": {"achieved": 79.74, "constraint": 31.25}},
    "utilization": {"ICESTORM_LC": {"available": 5280, "used": 27}, "SB_GB": {"available": 8, "used": 1},
                    "SB_IO": {"available": 39, "used": 2}, "ICESTORM_DSP": {"available": 8, "used": 0}},
}


def test_summarise_report_pass_and_fail():
    text, ok = fw.summarise_report(REPORT, 31.25)
    assert ok and "79.74 MHz" in text and "PASS" in text and re.search(r"ICESTORM_LC\s+27 / 5280", text)
    text, ok = fw.summarise_report(REPORT, 80.0)
    assert not ok and "FAIL" in text
    text, ok = fw.summarise_report({"fmax": {}, "utilization": {}}, 31.25)
    assert not ok and "no clock" in text


def test_fmax_results_require_both_constraint_and_request():
    r = fw.fmax_results({"fmax": {"c": {"achieved": 40.0, "constraint": 48.0}}}, 31.25)
    assert r == [("c", 40.0, 48.0, False)]


def test_build_runs_tools_and_packs(repo, monkeypatch, capsys):
    """Fake yosys/nextpnr/icepack via Runner.run so the pack + check + timing steps execute for real."""
    bits = fake_bitstream()
    calls = []

    def fake_run(self, cmd, check=True, capture=False):
        cmd = [str(c) for c in cmd]
        calls.append(cmd)
        bdir = repo.build / "hello_blink"
        if cmd[0] == "nextpnr-ice40":
            (bdir / "report.json").write_text(json.dumps(REPORT))
        if cmd[0] == "icepack":
            (bdir / "hello_blink.bin").write_bytes(bits)
        import subprocess
        return subprocess.CompletedProcess(cmd, 0, "", "")

    monkeypatch.setattr(fw.Runner, "run", fake_run)
    monkeypatch.setattr(fw.Runner, "tool", lambda self, name: name)
    monkeypatch.setattr(fw, "tool_version", lambda name: "fake 1.0")
    rc, out = run_cli(repo, "build", "hello_blink", capsys=capsys)
    assert rc == 0, out.err
    # the netlist pad check (python fpga/sim/check_netlist_pads.py) runs between yosys and nextpnr
    tools_only = [c[0] for c in calls if not c[0].lower().endswith(("python.exe", "python", "python3", "python3.exe"))]
    assert tools_only == ["yosys", "nextpnr-ice40", "icepack"]
    assert any("check_netlist_pads.py" in " ".join(map(str, c)) for c in calls)
    cont = repo.build / "hello_blink" / "hello_blink.fwfpga"
    header, manifest, bs = ff.validate(cont.read_bytes())
    assert bs == bits and header.name == "hello_blink"
    m = json.loads(manifest)
    assert m["tools"]["yosys"] == "fake 1.0" and m["build"]["freq_mhz"] == 31.25
    assert (repo.build / "hello_blink" / "fw2_design_id.vh").read_text().startswith("// fw2_design_id.vh")
    assert "PASS" in out.out and "drives: GPIO26" in out.out

    # timing failure -> nonzero even though the container is written
    rc, out = run_cli(repo, "build", "hello_blink", "--freq", "90", capsys=capsys)
    assert rc == 1 and "timing not met" in out.err


# --------------------------------------------------------------------------- new-design

def test_new_design(repo, capsys):
    rc, out = run_cli(repo, "new-design", "pwm8", capsys=capsys)
    assert rc == 0, out.err
    d = repo.designs / "pwm8"
    toml = (d / "design.toml").read_text()
    assert 'name = "pwm8"' in toml and "design_id = 2" in toml      # hello_blink is 1, stock is 0xFFFF
    assert (d / "tb" / "tb_pwm8.v").exists()
    assert "// pwm8" in (d / "user_core.v").read_text()
    assert dt.load_design(d).design_id == 2
    rc, out = run_cli(repo, "new-design", "pwm8", capsys=capsys)
    assert rc == 1 and "already exists" in out.err
    rc, out = run_cli(repo, "new-design", "Bad-Name", capsys=capsys)
    assert rc == 1
    rc, out = run_cli(repo, "--print", "new-design", "pwm9", capsys=capsys)
    assert rc == 0 and "design_id = 3" in out.out and not (repo.designs / "pwm9").exists()


# --------------------------------------------------------------------------- inspect

def test_inspect(repo, tmp_path, capsys):
    d = dt.from_dict(tomllib.loads(GOOD_TOML))
    f = tmp_path / "x.fwfpga"
    f.write_bytes(pk.pack_design(d, fake_bitstream(), {"k": 1}))
    rc, out = run_cli(repo, "inspect", str(f), "--manifest", capsys=capsys)
    assert rc == 0 and "drives: GPIO26" in out.out and '"k": 1' in out.out and "SPI1 MISO" in out.out
    f.write_bytes(fake_bitstream())
    rc, out = run_cli(repo, "inspect", str(f), capsys=capsys)
    assert rc == 1 and "magic" in out.err


# --------------------------------------------------------------------------- frames + fake serial

def test_parse_frames():
    frames, rest = fw.parse_frames("junk[h\\f\\s 0DE8F442FBC41063 14 stock 0xFFFF cdone 1 1][*fpgadl 1A 2 50% 1]tail")
    assert len(frames) == 2
    assert frames[0].path == "h\\f\\s" and frames[0].payload == "stock 0xFFFF cdone 1" and frames[0].ok
    assert frames[1].is_event and frames[1].payload == "50%"
    assert rest == "tail"
    frames, rest = fw.parse_frames("[h\\f\\l 1 2 partial")
    assert frames == [] and rest.startswith("[h")


class FakeSerial:
    """Scripted device: each entry in `script` is (expected_bytes_substring, reply_bytes)."""

    def __init__(self, replies):
        self.replies = list(replies)
        self.written = b""
        self.rx = b""

    def write(self, data):
        self.written += data
        for i, (trigger, reply) in enumerate(self.replies):
            if trigger is None or trigger in self.written:
                self.replies.pop(i)
                self.rx += reply
                break

    @property
    def in_waiting(self):
        return len(self.rx)

    def read(self, n):
        out, self.rx = self.rx[:n], self.rx[n:]
        return out

    def close(self):
        pass


def test_wire_command_bytes_and_reply():
    ser = FakeSerial([(b"h\\f\\s\n", b"garbage[h\\f\\s 0DE8 1 cdone 1 id 7 1]")])
    w = fw.Wire(ser)
    f = w.command("h\\f\\s")
    assert ser.written == b"\x03h\\f\\s\n"
    assert f.payload == "cdone 1 id 7" and f.ok


def test_wire_command_with_args_ignores_other_frames():
    ser = FakeSerial([(b'h\\f\\l "/fpga/x.fwfpga"\n', b"[*fpgadl 1 1 10% 1][i\\g\\u 1 2 E0 1][h\\f\\l 1 3 1 1 1 412 1]")])
    w = fw.Wire(ser)
    f = w.command("h\\f\\l", '"/fpga/x.fwfpga"')
    assert f.path == "h\\f\\l" and f.payload == "1 1 1 412"
    assert len(w.events) == 1 and w.events[0].path == "*fpgadl"


def test_wire_timeout():
    w = fw.Wire(FakeSerial([]))
    with pytest.raises(fw.WireTimeout, match="timeout"):
        w.command("h\\f\\s", timeout=0.05)


def test_put_file_single_line_form():
    data = b"\x7e\xaa\x99\x7e" + bytes(range(256)) * 20
    crc = zlib.crc32(data) & 0xFFFFFFFF
    hdr = f"/fpga/x.fwfpga {len(data)} {crc}".encode()
    ser = FakeSerial([
        (b"h\\x\\f " + hdr + b"\n", b"[h\\x\\f 1 1 Send File Now 1]"),
        (data[-16:], b"[x\\f 1 2 success %d bytes 1]" % len(data)),
    ])
    w = fw.Wire(ser)
    result = w.put_file(data, "/fpga/x.fwfpga", timeout=0.5)
    assert result == f"success {len(data)} bytes"
    assert ser.written.startswith(b"\x03h\\x\\f " + hdr + b"\n")
    assert ser.written.endswith(data)
    assert ser.written.count(data) == 1


def test_put_file_falls_back_to_stepwise():
    data = bytes(100)
    crc = zlib.crc32(data) & 0xFFFFFFFF
    hdr = f"/fpga/y.fwfpga 100 {crc}\n".encode()
    ser = FakeSerial([
        (b"f\n" + hdr, b"[h\\x\\f 1 1 Send File Now 1]"),   # only answers the stepwise form
        (data, b"[x\\f 1 2 success 100 bytes 1]"),
    ])
    w = fw.Wire(ser)
    assert w.put_file(data, "/fpga/y.fwfpga", timeout=0.1) == "success 100 bytes"
    assert b"\x03h\nx\nf\n" + hdr in ser.written
    # the single-line attempt came first
    assert ser.written.index(b"h\\x\\f ") < ser.written.index(b"\x03h\nx\nf\n")


def test_put_file_refusal_and_checksum_failure():
    data = bytes(10)
    ser = FakeSerial([(b"h\\x\\f", b"[h\\x\\f 1 1 Invalid 0]")])
    with pytest.raises(fw.CliError, match="refused"):
        fw.Wire(ser).put_file(data, "/fpga/z.fwfpga", timeout=0.1)
    ser = FakeSerial([(b"h\\x\\f", b"[h\\x\\f 1 1 Send File Now 1]"), (data, b"[x\\f 1 2 Failed checksum 0]")])
    with pytest.raises(fw.CliError, match="failed"):
        fw.Wire(ser).put_file(data, "/fpga/z.fwfpga", timeout=0.1)


def test_put_file_explicit_stepwise():
    data = bytes(10)
    ser = FakeSerial([(b"f\n", b"[h\\x\\f 1 1 Send File Now 1]"), (data, b"[x\\f 1 2 success 10 bytes 1]")])
    fw.Wire(ser).put_file(data, "/fpga/z.fwfpga", stepwise=True, timeout=0.1)
    assert b"h\\x\\f" not in ser.written and ser.written.startswith(b"\x03h\nx\nf\n/fpga/z.fwfpga 10 ")


# --------------------------------------------------------------------------- device commands, --print

def test_device_commands_print_exact_bytes(repo, capsys):
    cases = [
        (["load", "hello_blink"], "send b'\\x03'\nsend b'h\\\\f\\\\l \"/fpga/hello_blink.fwfpga\"\\n'"),
        (["load", "build/designs/x/other.fwfpga"], "send b'h\\\\f\\\\l \"/fpga/other.fwfpga\"\\n'"),
        (["load", "/sd/custom/path.fwfpga"], "send b'h\\\\f\\\\l \"/sd/custom/path.fwfpga\"\\n'"),
        (["restore"], "send b'h\\\\f\\\\t\\n'"),
        (["status"], "send b'h\\\\f\\\\s\\n'"),
        (["reg", "r", "0x10"], "send b'h\\\\f\\\\r 10 1\\n'"),
        (["reg", "r", "0x70", "16"], "send b'h\\\\f\\\\r 70 16\\n'"),
        (["reg", "w", "0x10", "0x80"], "send b'h\\\\f\\\\w 10 80\\n'"),
        (["reg", "w", "16", "128"], "send b'h\\\\f\\\\w 10 80\\n'"),
        (["reg", "w", "0x10", "80AB"], "send b'h\\\\f\\\\w 10 80 AB\\n'"),
        (["reg", "w", "0x10", "1", "2", "3"], "send b'h\\\\f\\\\w 10 01 02 03\\n'"),
        (["stream", "rx", "4096"], "send b'h\\\\f\\\\c 4096 \\\\fpga\\\\cap.bin\\n'"),
        (["stream", "rx", "256"], "send b'h\\\\f\\\\x 256\\n'"),
    ]
    for argv, expected in cases:
        rc, out = run_cli(repo, "--print", *argv, capsys=capsys)
        assert rc == 0, (argv, out.err)
        assert expected in out.out, (argv, out.out)
    assert fw.WIRE["restore"] == "h\\f\\t"      # `d` is reserved by the menu system


def test_reg_argument_validation(repo, capsys):
    rc, out = run_cli(repo, "--print", "reg", "r", "0x80", capsys=capsys)
    assert rc == 1 and "out of range" in out.err
    rc, out = run_cli(repo, "--print", "reg", "w", "0x10", capsys=capsys)
    assert rc == 1 and "needs" in out.err
    rc, out = run_cli(repo, "--print", "reg", "w", "0x10", "256", capsys=capsys)
    assert rc == 1
    rc, out = run_cli(repo, "--print", "reg", "r", "ten", capsys=capsys)
    assert rc == 1 and "integer" in out.err
    rc, out = run_cli(repo, "--print", "reg", "r", "0x10", "1", "2", capsys=capsys)
    assert rc == 1 and "count" in out.err


def test_status_parsing():
    f = fw.Frame("h\\f\\s", "1", 1, "stock 0 1 0 0 00 31245000 00000000 - 0 -", True, "")
    st = fw.parse_status(f.payload)
    assert st["source"] == "stock" and st["clock_hz"] == "31245000" and st["profile"] == "00000000"
    text = fw.format_status(f)
    assert "source   stock" in text and "31245000 Hz" in text and "profile  00000000: stock passthrough" in text
    import profile as iop
    packed = iop.pack(dict(iop.STOCK_PROFILE, gpio26="FPGA_OUT"))
    f = fw.Frame("h\\f\\s", "1", 1, f"file 1 1 7 1 03 31250000 {packed:08X} hello_blink 412 -", True, "")
    text = fw.format_status(f)
    assert "drives: GPIO26" in text and "IO_BUFFER, STREAM" in text and "name hello_blink" in text
    assert fw.format_status(fw.Frame("h\\f\\s", "1", 1, "Invalid", False, "")) == "Invalid"
    # F3b firmware appends the contention field
    assert st["contention"] is None
    f = fw.Frame("h\\f\\s", "1", 1, f"file 1 1 7 1 03 31250000 {packed:08X} hello_blink 412 - -", True, "")
    assert fw.parse_status(f.payload)["contention"] == "-" and "self-checks: clean" in fw.format_status(f)
    f = fw.Frame("h\\f\\s", "1", 1, f"file 1 1 7 1 03 31250000 {packed:08X} hello_blink 412 - fabric:gpio26", True, "")
    assert "FOUND fabric:gpio26" in fw.format_status(f)


def test_install_print_and_refusals(repo, capsys):
    d = dt.from_dict(tomllib.loads(GOOD_TOML))
    bdir = repo.build / "hello_blink"
    bdir.mkdir(parents=True)
    cont = bdir / "hello_blink.fwfpga"
    blob = pk.pack_design(d, fake_bitstream(), None)
    cont.write_bytes(blob)
    rc, out = run_cli(repo, "--print", "install", "hello_blink", capsys=capsys)
    assert rc == 0, out.err
    assert "header matches" in out.out
    crc = zlib.crc32(blob) & 0xFFFFFFFF
    assert f"send b'h\\\\x\\\\f /fpga/hello_blink.fwfpga {len(blob)} {crc}\\n'" in out.out
    assert f"send <{len(blob)} raw bytes>" in out.out
    rc, out = run_cli(repo, "--print", "install", str(cont), "--dest", "/fpga/alt.fwfpga", "--stepwise", capsys=capsys)
    assert rc == 0 and "send b'h\\n'\nsend b'x\\n'\nsend b'f\\n'\nsend b'/fpga/alt.fwfpga " in out.out

    # a bare .bin and a corrupted container are refused before any byte goes out
    binf = bdir / "raw.bin"
    binf.write_bytes(fake_bitstream())
    rc, out = run_cli(repo, "--print", "install", str(binf), capsys=capsys)
    assert rc == 1 and "refusing" in out.err and "send" not in out.out
    bad = bytearray(blob)
    bad[400] ^= 1
    cont.write_bytes(bad)
    rc, out = run_cli(repo, "--print", "install", "hello_blink", capsys=capsys)
    assert rc == 1 and "CRC32" in out.err
    # header no longer matching designs/<name>/design.toml is refused too
    cont.write_bytes(blob)
    (repo.designs / "hello_blink" / "design.toml").write_text(GOOD_TOML.replace("design_id = 1", "design_id = 9"))
    rc, out = run_cli(repo, "--print", "install", "hello_blink", capsys=capsys)
    assert rc == 1 and "design_id: header 1 != design.toml 9" in out.err
    rc, out = run_cli(repo, "--print", "install", "unbuilt", capsys=capsys)
    assert rc == 1 and "fwfpga build unbuilt" in out.err


def test_load_reply_parsing_and_status_profile_decode():
    f = fw.Frame("h\\f\\l", "1", 1, "7 1 1 412", True, "")
    assert fw.parse_load_reply(f) == "design_id 7  version 1  cdone 1  load_ms 412"
    f = fw.Frame("h\\f\\l", "1", 1, "Invalid", False, "")
    assert fw.parse_load_reply(f) == "Invalid"


def test_launchers_exist():
    tools = Path(fw.__file__).parent
    assert (tools / "fwfpga").read_text().startswith("#!/bin/sh")
    assert "fwfpga.py" in (tools / "fwfpga.cmd").read_text()


def test_test_command_print(repo, capsys):
    (repo.root / "tools" / "tests").mkdir(parents=True)
    (repo.root / "tests").mkdir()
    rc, out = run_cli(repo, "--print", "test", "--no-sim", capsys=capsys)
    assert rc == 0 and "-m pytest -q" in out.out and "tools/tests" in out.out.replace("\\", "/")
