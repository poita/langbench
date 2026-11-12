"""High-level helpers tying parsing, evaluation and output formatting together."""

from __future__ import annotations

from .engine import Model, evaluate
from .errors import DatalogError
from .parser import parse
from .syntax import ConstantValue, Program


def format_row(pred: str, row: tuple[ConstantValue, ...]) -> str:
    """``p(v1, v2, ...)``."""
    return f"{pred}({', '.join(map(str, row))})"


def answer(model: Model, program: Program) -> str:
    """Answer every query of ``program`` against ``model``: the matching
    tuples one per line, then ``-- N``."""
    out: list[str] = []
    for q in program.queries:
        rows = model.query(q)
        out.extend(format_row(q.atom.pred, r) for r in rows)
        out.append(f"-- {len(rows)}")
    return "".join(line + "\n" for line in out)


def run(text: str) -> str:
    """Run a program text and return the exact output of the command-line tool:
    the query answers, or ``error\\n`` if the program is malformed, unsafe or
    not stratifiable."""
    try:
        program = parse(text)
        model = evaluate(program)
    except DatalogError:
        return "error\n"
    return answer(model, program)
