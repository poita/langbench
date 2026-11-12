import io
import os
import subprocess
import sys
from pathlib import Path

import pytest

from qrcode import cli

ROOT = Path(__file__).resolve().parent.parent


def run_cli(data: bytes):
    out = io.BytesIO()
    code = cli.run(io.BytesIO(data), out)
    return code, out.getvalue().decode()


def test_single_query_format():
    code, out = run_cli(b"M 0 HELLO WORLD\n")
    assert code == 0
    lines = out.split("\n")
    assert lines[0] == "version 1 mask 0"
    assert len(lines) == 1 + 21 + 2  # header, rows, blank, trailing ''
    assert lines[22] == "" and lines[23] == ""
    assert lines[1] == "#######...#.#.#######"


def test_final_newline_optional_and_multiple_queries():
    a = run_cli(b"L auto 01234567\nH 5 h\xc3\xa9llo")
    b = run_cli(b"L auto 01234567\nH 5 h\xc3\xa9llo\n")
    assert a == b
    assert a[1].count("version") == 2
    assert a[1].endswith("\n\n")


def test_text_with_interior_spaces():
    code, out = run_cli(b"L 0 a b  c\n")
    assert code == 0
    assert out.startswith("version 1 mask 0\n")


@pytest.mark.parametrize(
    "line", [b"X 0 hi", b"L 8 hi", b"L auto", b"L", b"L  hi", b"l 0 hi"]
)
def test_bad_queries_fail(line):
    code, _ = run_cli(line + b"\n")
    assert code == 1


def test_parse_query():
    assert cli.parse_query(b"Q auto x y")[1:] == (None, b"x y")


def test_run_sh_end_to_end():
    script = ROOT / "run.sh"
    proc = subprocess.run(
        [str(script)], input=b"M 0 HELLO WORLD\n", capture_output=True, cwd="/", check=True
    )
    assert proc.stdout.decode().startswith("version 1 mask 0\n#######...#.#.#######\n")
