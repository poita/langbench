import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run_cli(stdin: str) -> subprocess.CompletedProcess:
    env = dict(os.environ, PYTHONPATH=str(ROOT / "src"))
    return subprocess.run([sys.executable, "-m", "cardgame"], input=stdin,
                          capture_output=True, text=True, env=env)


def test_cli_fatal_exits_zero():
    proc = run_cli("START\n")
    assert proc.returncode == 0
    assert proc.stdout == "FATAL bad-setup\n"


def test_cli_runs_a_match(db_path):
    proc = run_cli("CARDS %s\nSEED 1\nOPENING 0\nSHUFFLE off\nSTART\n"
                   % db_path)
    assert proc.returncode == 0
    assert proc.stdout.splitlines()[-1] == "8 RESULT pending none"


def test_run_sh_works_from_any_directory(tmp_path):
    proc = subprocess.run([str(ROOT / "run.sh")], input="START\n",
                          capture_output=True, text=True, cwd=tmp_path)
    assert proc.stdout == "FATAL bad-setup\n"
