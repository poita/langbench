"""DIMACS CNF parsing and SAT-competition-style result formatting."""

from __future__ import annotations

from typing import List, NamedTuple, Optional, Sequence


class Cnf(NamedTuple):
    """A parsed formula: ``num_vars`` variables and DIMACS-style clauses."""

    num_vars: int
    clauses: List[List[int]]


def parse_dimacs(text: str) -> Cnf:
    """Parse DIMACS CNF text.

    Lines whose first non-blank character is ``c`` are comments and blank
    lines are skipped; both may appear anywhere. The ``p cnf V C`` header
    gives the variable count. All other lines hold integers; a clause is a run
    of non-zero integers ended by ``0`` and may span lines or share a line
    with other clauses. A trailing unterminated run is ignored.
    """
    num_vars = 0
    clauses: List[List[int]] = []
    current: List[int] = []
    for line in text.split("\n"):
        stripped = line.strip(" \t\r")
        if not stripped or stripped[0] == "c":
            continue
        if stripped[0] == "p":
            parts = stripped.split()
            num_vars = int(parts[2])
            continue
        for token in stripped.split():
            lit = int(token)
            if lit:
                current.append(lit)
            else:
                clauses.append(current)
                current = []
    return Cnf(num_vars, clauses)


def format_result(model: Optional[Sequence[int]]) -> str:
    """Render a solver result.

    ``model`` is ``None`` for UNSAT, otherwise the list of signed literals
    ``[±1, ±2, ..., ±V]``. Returns ``"UNSAT\\n"`` or ``"SAT\\n<lits> 0\\n"``.
    """
    if model is None:
        return "UNSAT\n"
    return "SAT\n" + " ".join(map(str, [*model, 0])) + "\n"
