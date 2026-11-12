import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run(text):
    env = dict(os.environ, PYTHONPATH=os.path.join(ROOT, "src"))
    r = subprocess.run(
        [sys.executable, "-m", "cdcl_sat"], input=text, capture_output=True, text=True, env=env
    )
    assert r.returncode == 0
    return r.stdout


def test_sat():
    out = run("c x\np cnf 3 2\n1 -2 0\n2 3 0\n")
    lines = out.split("\n")
    assert lines[0] == "SAT" and lines[2] == ""
    lits = [int(t) for t in lines[1].split()]
    assert lits[-1] == 0 and [abs(l) for l in lits[:-1]] == [1, 2, 3]
    m = {abs(l): l > 0 for l in lits[:-1]}
    assert (m[1] or not m[2]) and (m[2] or m[3])


def test_unsat():
    assert run("p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0") == "UNSAT\n"


def test_zero_vars():
    assert run("p cnf 0 0") == "SAT\n0\n"
    assert run("p cnf 0 1\n0\n") == "UNSAT\n"


def test_unused_variables_listed():
    out = run("p cnf 5 1\n2 0\n")
    assert len(out.split("\n")[1].split()) == 6
