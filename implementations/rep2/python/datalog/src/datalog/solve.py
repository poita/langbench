"""One-call entry point: program text in, query output text out."""

from __future__ import annotations

from .engine import evaluate
from .formatting import format_tuple
from .parser import parse


def solve(source: str) -> str:
    """Parse and evaluate ``source`` and return the text the command-line tool
    prints: for each query its matching tuples, one per line, then ``-- N``.

    Raises a :class:`~datalog.errors.DatalogError` if the program is malformed,
    unsafe or not stratifiable.
    """
    program = parse(source)
    model = evaluate(program)
    out: list[str] = []
    for query in program.queries:
        rows = model.query(query)
        out.extend(format_tuple(query.predicate, row) for row in rows)
        out.append(f"-- {len(rows)}")
    return "\n".join(out) + "\n" if out else ""
