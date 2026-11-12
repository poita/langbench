import subprocess
import sys
from pathlib import Path

import pytest

from datalog import StratificationError, UnsafeRuleError, solve

ROOT = Path(__file__).resolve().parent.parent

EX1 = """
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(1, X).
?- path(4, X).
?- path(X, X).
"""
OUT1 = """path(1, 1)
path(1, 2)
path(1, 3)
path(1, 4)
-- 4
-- 0
path(1, 1)
path(2, 2)
path(3, 3)
-- 3
"""

EX2 = """
% nodes and links
node(a). node(b). node(c). node(5). node(-2).
link(a, b). link(b, 5). link(5, 5).
reach(X, Y) :- link(X, Y).
reach(X, Z) :- reach(X, Y), link(Y, Z).
sink(X) :- node(X), not hasout(X).
hasout(X) :- link(X, _).
small(X) :- node(X), X < a.
?- sink(X).
?- small(X).
?- reach(a, X).
?- reach(X, X).
"""
OUT2 = """sink(-2)
sink(c)
-- 2
small(-2)
small(5)
-- 2
reach(a, 5)
reach(a, b)
-- 2
reach(5, 5)
-- 1
"""


def run_cli(text):
    return subprocess.run([str(ROOT / "run.sh")], input=text, capture_output=True, text=True)


def test_solve_examples():
    assert solve(EX1) == OUT1
    assert solve(EX2) == OUT2


def test_no_queries_no_output():
    assert solve("p(1).") == ""
    assert solve("  % nothing\n") == ""


def test_solve_raises():
    with pytest.raises(StratificationError):
        solve("e(1, 2). win(X) :- e(X, Y), not win(Y). ?- win(X).")
    with pytest.raises(UnsafeRuleError):
        solve("q(1). ?- q(X). p(X) :- q(Y). ?- p(X).")


def test_queries_answered_in_order_after_whole_program():
    assert solve("?- p(X). p(1). ?- q(X). q(2).") == "p(1)\n-- 1\nq(2)\n-- 1\n"


@pytest.mark.parametrize("src", ["q(1). ?- q(X). p(X) :- q(Y). ?- p(X).",
                                 "win(X) :- e(X, Y), not win(Y).", "p(X)."])
def test_cli_error(src):
    r = run_cli(src)
    assert r.returncode == 0
    assert r.stdout == "error\n"


def test_cli_output():
    r = run_cli(EX2)
    assert r.returncode == 0 and r.stdout == OUT2


def test_cli_empty_input():
    r = run_cli("")
    assert r.returncode == 0 and r.stdout == ""


def test_module_entry_point():
    r = subprocess.run([sys.executable, "-m", "datalog"], input=EX1, capture_output=True, text=True,
                       env={"PYTHONPATH": str(ROOT / "src"), "PATH": ""})
    assert r.stdout == OUT1
