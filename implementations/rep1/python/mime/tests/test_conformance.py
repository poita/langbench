"""Run the repository's example suite (problems/mime/tests) if it is present."""

from pathlib import Path

import pytest

from mimedump import dump_mailbox

SUITE = Path(__file__).resolve().parents[2] / "problems" / "mime" / "tests"
CASES = sorted(p for p in SUITE.iterdir() if (p / "input").exists()) if SUITE.is_dir() else []


def _files(root: Path):
    return sorted(p.relative_to(root) for p in root.rglob("*") if p.is_file())


@pytest.mark.skipif(not CASES, reason="example suite not found")
@pytest.mark.parametrize("case", CASES, ids=lambda p: p.name)
def test_case(case, tmp_path):
    dump_mailbox(str(case / "input"), str(tmp_path))
    expected = case / "expected"
    assert _files(tmp_path) == _files(expected)
    for rel in _files(expected):
        got = (tmp_path / rel).read_bytes()
        want = (expected / rel).read_bytes()
        if rel.suffix == ".bin":
            assert got == want, rel
        else:
            norm = lambda b: [l.rstrip() for l in b.decode().rstrip("\n").split("\n")]
            assert norm(got) == norm(want), rel
