"""Command-line interface: DIMACS CNF on stdin, ``SAT``/``UNSAT`` on stdout."""

from __future__ import annotations

import sys
from typing import Optional, Sequence

from .dimacs import format_result, parse_dimacs
from .solver import solve


def main(argv: Optional[Sequence[str]] = None) -> int:
    cnf = parse_dimacs(sys.stdin.read())
    model = solve(cnf.num_vars, cnf.clauses)
    sys.stdout.write(format_result(cnf.num_vars, model))
    return 0
