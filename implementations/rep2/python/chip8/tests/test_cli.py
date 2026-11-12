import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run_cli(stdin: str, cwd=None) -> subprocess.CompletedProcess:
    env = dict(os.environ, PYTHONPATH=str(ROOT / "src"))
    return subprocess.run(
        [sys.executable, "-m", "chip8"],
        input=stdin, capture_output=True, text=True, env=env, cwd=cwd,
    )


def test_cli_example1(tmp_path):
    r = run_cli("60ff7001610180141208\n6", cwd=tmp_path)
    assert r.returncode == 0
    lines = r.stdout.split("\n")
    assert len(lines) == 35 and lines[34] == ""
    assert lines[32] == "PC=0208 I=0000 SP=0 DT=00 ST=00"


def test_run_sh(tmp_path):
    r = subprocess.run(
        [str(ROOT / "run.sh")], input="6001\n1\n", capture_output=True,
        text=True, cwd=tmp_path,
    )
    assert r.returncode == 0
    assert r.stdout.split("\n")[33].startswith("V=01 00")
