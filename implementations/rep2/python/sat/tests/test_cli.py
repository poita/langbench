import subprocess
import sys
from pathlib import Path

from conftest import make_rng, pigeonhole, random_cnf, satisfies

SRC = str(Path(__file__).resolve().parents[1] / "src")


def run_cli(text, *args):
    return subprocess.run(
        [sys.executable, "-m", "cdcl_sat", *args],
        input=text, capture_output=True, text=True,
        env={"PYTHONPATH": SRC},
    )


def test_sat_example():
    r = run_cli("c example\np cnf 3 2\n1 -2 0\n2 3 0\n")
    assert r.returncode == 0
    lines = r.stdout.split("\n")
    assert lines[0] == "SAT" and lines[-1] == ""
    lits = list(map(int, lines[1].split()))
    assert lits[-1] == 0 and [abs(x) for x in lits[:-1]] == [1, 2, 3]
    assert satisfies(lits[:-1], [[1, -2], [2, 3]])


def test_unsat_example():
    r = run_cli("p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0\n")
    assert (r.returncode, r.stdout) == (0, "UNSAT\n")


def test_zero_variables():
    r = run_cli("p cnf 0 0")
    assert (r.returncode, r.stdout) == (0, "SAT\n0\n")


def test_pigeonhole_via_cli():
    n, clauses = pigeonhole(4)
    text = f"p cnf {n} {len(clauses)}\n" + "".join(
        " ".join(map(str, c)) + " 0\n" for c in clauses
    )
    assert run_cli(text).stdout == "UNSAT\n"


def test_random_sat_via_cli():
    clauses = random_cnf(make_rng(3), 30, 90)
    text = f"p cnf 30 {len(clauses)}\n" + "".join(
        " ".join(map(str, c)) + " 0\n" for c in clauses
    )
    out = run_cli(text).stdout.split("\n")
    if out[0] == "SAT":
        lits = list(map(int, out[1].split()))
        assert satisfies(lits[:-1], clauses)
    else:
        assert out[0] == "UNSAT"


def test_help():
    assert run_cli("", "--help").returncode == 0
