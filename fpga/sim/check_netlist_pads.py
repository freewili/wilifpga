#!/usr/bin/env python3
"""Gate-level pad check on a yosys JSON netlist of fw2_shell.

    python fpga/sim/check_netlist_pads.py build/designs/hello_blink/hello_blink.json

Fails (exit 1) if any `inout` port of the top is tied to a constant (yosys
folds `assign PAD = 1'bz` / a constant-0 output enable into a DRIVEN constant,
which is how hello_blink drove header SDA low on 2026-10-31) or is not driven by
an SB_IO with a tri-state PIN_TYPE. Prints every pad with its SB_IO PIN_TYPE and
whether the output enable is constant. Pure Python, no toolchain needed.
"""
import json
import sys


def main(path):
    top = json.load(open(path))["modules"]["fw2_shell"]
    ports, cells = top["ports"], top["cells"]
    by_pin = {}
    for name, c in cells.items():
        if c["type"] == "SB_IO":
            pin = tuple(c["connections"].get("PACKAGE_PIN", []))
            by_pin[pin] = (name, c)
    errors = 0
    for pname, p in sorted(ports.items()):
        if p["direction"] != "inout":
            continue
        bits = p["bits"]
        if any(isinstance(b, str) for b in bits):
            print(f"FAIL {pname}: inout port tied to constant {bits} (pad is DRIVEN)")
            errors += 1
            continue
        hit = by_pin.get(tuple(bits))
        if hit is None:
            print(f"FAIL {pname}: no SB_IO on this pad")
            errors += 1
            continue
        name, c = hit
        pin_type = c["parameters"]["PIN_TYPE"]
        pin_type_s = pin_type if isinstance(pin_type, str) else format(pin_type, "06b")
        oe = c["connections"].get("OUTPUT_ENABLE", [])
        oe_s = "const %s" % oe[0] if oe and isinstance(oe[0], str) else "net"
        tristate = pin_type_s[:4] in ("1010", "1011", "1110", "1111", "1000", "1001", "1100", "1101")
        if not tristate:
            print(f"FAIL {pname}: SB_IO PIN_TYPE {pin_type_s} is not a tri-state output type")
            errors += 1
        else:
            print(f"ok   {pname:13s} SB_IO PIN_TYPE {pin_type_s} OUTPUT_ENABLE {oe_s}")
    print("check_netlist_pads:", "PASS" if errors == 0 else f"{errors} FAIL")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
