import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run_cli(stdin: str) -> subprocess.CompletedProcess:
    env = dict(os.environ, PYTHONPATH=str(ROOT / "src"))
    return subprocess.run([sys.executable, "-m", "datalog"], input=stdin, text=True,
                          capture_output=True, env=env, timeout=60)


def test_cli_answers_queries():
    r = run_cli("e(1,2). e(2,3). p(X,Y):-e(X,Y). p(X,Z):-e(X,Y),p(Y,Z). ?- p(1,X).")
    assert r.returncode == 0
    assert r.stdout == "p(1, 2)\np(1, 3)\n-- 2\n"


def test_cli_error_exit_code_zero():
    r = run_cli("p(X).")
    assert (r.returncode, r.stdout) == (0, "error\n")


def test_cli_empty_input():
    r = run_cli("")
    assert (r.returncode, r.stdout) == (0, "")


def test_run_script():
    r = subprocess.run([str(ROOT / "run.sh")], input="p(a). ?- p(X).", text=True,
                       capture_output=True, cwd="/", timeout=60)
    assert r.stdout == "p(a)\n-- 1\n"
