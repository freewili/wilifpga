"""Every design in designs/ parses, has a unique id, and documents itself.

No toolchain, no hardware: only tools/design_toml.py and the
files under designs/.
"""
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import design_toml  # noqa: E402

DESIGN_DIRS = sorted(p for p in (ROOT / "designs").iterdir() if (p / "design.toml").exists())
README_SECTIONS = ("What you learn", "Build", "Install", "Verify", "Pins used", "Registers")


@pytest.mark.parametrize("design_dir", DESIGN_DIRS, ids=[p.name for p in DESIGN_DIRS])
def test_design_toml_loads_and_matches_folder(design_dir):
    d = design_toml.load_design(design_dir / "design.toml")
    assert d.name == design_dir.name
    assert len(d.version_str) == 3 and d.version_str.isdigit() and 0 <= d.version <= 999
    assert (design_dir / "README.md").exists(), "every design ships a README"


def test_design_ids_unique():
    ids = {}
    for p in DESIGN_DIRS:
        d = design_toml.load_design(p / "design.toml")
        assert d.design_id not in ids, f"{p.name} reuses design_id {d.design_id} of {ids.get(d.design_id)}"
        ids[d.design_id] = p.name
    assert ids, "no designs found"


@pytest.mark.parametrize("design_dir", DESIGN_DIRS, ids=[p.name for p in DESIGN_DIRS])
def test_design_readme_has_required_sections(design_dir):
    text = (design_dir / "README.md").read_text(encoding="utf-8")
    missing = [s for s in README_SECTIONS if s.lower() not in text.lower()]
    assert not missing, f"{design_dir.name}/README.md lacks sections: {missing}"


@pytest.mark.parametrize("design_dir", DESIGN_DIRS, ids=[p.name for p in DESIGN_DIRS])
def test_user_designs_have_user_core_and_tb(design_dir):
    d = design_toml.load_design(design_dir / "design.toml")
    if d.kind == "stock":
        pytest.skip("stock passthrough keeps the stock top")
    assert (design_dir / "user_core.v").exists()
    assert any((design_dir / "tb").glob("*.v")), "every user design has a testbench"
