import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def cli(stdin: str):
    return subprocess.run(
        [sys.executable, "-m", "depresolve"],
        input=stdin.encode(),
        capture_output=True,
        env={"PYTHONPATH": str(ROOT / "src")},
    )


def test_cli_resolves():
    p = cli("a 1.0.0: b *\nb 2.0.0:\nb 1.0.0:\nroot: a *\n")
    assert p.returncode == 0 and p.stdout == b"a 1.0.0\nb 2.0.0\n"


def test_cli_unsatisfiable():
    p = cli("root: x *\n")
    assert p.returncode == 0 and p.stdout == b"unsatisfiable\n"


def test_cli_empty_output():
    p = cli("root:\n")
    assert p.returncode == 0 and p.stdout == b""
