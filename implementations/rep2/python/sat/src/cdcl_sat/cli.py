"""Command-line interface: read DIMACS CNF on stdin, print the verdict."""

from __future__ import annotations

import sys
from typing import Sequence

from .dimacs import format_result, parse_dimacs
from .solver import solve


def main(argv: Sequence[str] | None = None) -> int:
    """Run the CLI. Reads stdin, writes ``SAT``/``UNSAT`` (+model) to stdout.

    The exit status is 0 for both satisfiable and unsatisfiable formulas.
    """
    args = list(sys.argv[1:] if argv is None else argv)
    if args:
        sys.stderr.write("usage: python3 -m cdcl_sat < input.cnf\n")
        return 0 if args[0] in ("-h", "--help") else 2
    cnf = parse_dimacs(sys.stdin.read())
    model = solve(cnf.clauses, cnf.num_vars)
    sys.stdout.write(format_result(model))
    return 0
