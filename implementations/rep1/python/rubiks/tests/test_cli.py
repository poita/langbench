import subprocess
import sys
from pathlib import Path

import pytest

from rubiks import Cube
from rubiks.cli import solve_text, split_lines

SRC = Path(__file__).resolve().parent.parent / "src"


@pytest.mark.parametrize("text, lines", [
    ("R", ["R"]),
    ("R\n", ["R"]),
    ("R\n\n", ["R", ""]),
    ("\n", [""]),
    ("R\nU", ["R", "U"]),
])
def test_split_lines(text, lines):
    assert split_lines(text) == lines


def test_solve_text_line_count_and_validity(solver):
    text = "F R U'\n\nR U R' U' R U R' U' R U R' U' R U R' U' R U R' U' R U R' U'\n"
    out = solve_text(text)
    assert out.endswith("\n")
    lines = out.split("\n")[:-1]
    assert len(lines) == 3
    assert lines[1] == "" and lines[2] == ""
    assert Cube.from_moves("F R U' " + lines[0]).is_solved()


def test_subprocess_roundtrip():
    proc = subprocess.run([sys.executable, "-m", "rubiks"], input=b"R\n\nU2",
                          capture_output=True, env={"PYTHONPATH": str(SRC)})
    assert proc.returncode == 0
    lines = proc.stdout.decode().split("\n")
    assert lines[-1] == "" and len(lines) == 4
    assert lines[1] == ""
    assert Cube.from_moves("R " + lines[0]).is_solved()
    assert Cube.from_moves("U2 " + lines[2]).is_solved()


def test_bad_token_fails():
    proc = subprocess.run([sys.executable, "-m", "rubiks"], input=b"Q\n",
                          capture_output=True, env={"PYTHONPATH": str(SRC)})
    assert proc.returncode == 1
    assert b"invalid move token" in proc.stderr
