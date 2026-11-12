"""DIMACS CNF parsing and result formatting."""

from __future__ import annotations

from typing import List, NamedTuple, Optional, Sequence


class CNF(NamedTuple):
    """A parsed formula: ``num_vars`` variables and a list of clauses of DIMACS literals."""

    num_vars: int
    clauses: List[List[int]]


def parse_dimacs(text: str) -> CNF:
    """Parse DIMACS CNF text.

    Blank lines and ``c`` comment lines are ignored anywhere; clauses are runs
    of integers terminated by ``0`` and may span lines or share a line. The
    header's clause count is not enforced.
    """
    num_vars = 0
    clauses: List[List[int]] = []
    cur: List[int] = []
    for line in text.split("\n"):
        s = line.strip(" \t\r")
        if not s:
            continue
        head = s[0]
        if head == "c":
            continue
        if head == "p":
            parts = s.split()
            num_vars = int(parts[2])
            continue
        for tok in s.split():
            x = int(tok)
            if x == 0:
                clauses.append(cur)
                cur = []
            else:
                cur.append(x)
    if cur:  # tolerate a missing final 0
        clauses.append(cur)
    return CNF(num_vars, clauses)


def format_result(num_vars: int, model: Optional[Sequence[bool]]) -> str:
    """Render a solver result.

    ``model`` is ``None`` for UNSAT, otherwise a sequence where ``model[i]`` is
    the value of variable ``i + 1``. Returns text ending in a newline.
    """
    if model is None:
        return "UNSAT\n"
    lits = [str(i + 1) if model[i] else str(-(i + 1)) for i in range(num_vars)]
    lits.append("0")
    return "SAT\n" + " ".join(lits) + "\n"
