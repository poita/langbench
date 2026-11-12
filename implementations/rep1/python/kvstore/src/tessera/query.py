"""Predicates: AST, evaluation and plan selection (SPEC §17)."""

from __future__ import annotations

from typing import Any, NamedTuple, Sequence, Union

from .indexkey import vkey
from .value import MISSING, deep_equal, get_path, rank

OPS = ("==", "!=", "<", "<=", ">", ">=")


class And(NamedTuple):
    left: "Predicate"
    right: "Predicate"


class Or(NamedTuple):
    left: "Predicate"
    right: "Predicate"


class Not(NamedTuple):
    operand: "Predicate"


class Exists(NamedTuple):
    segs: tuple[str, ...]


class Missing(NamedTuple):
    segs: tuple[str, ...]


class Cmp(NamedTuple):
    """``path op value``; ``value`` is a Tessera value."""
    segs: tuple[str, ...]
    op: str
    value: Any


Predicate = Union[And, Or, Not, Exists, Missing, Cmp]


def compare(x: Any, op: str, value: Any) -> bool:
    """``x op value`` for a present ``x`` (SPEC §17.2)."""
    rx = rank(x)
    same = rx == rank(value)
    if op == "==":
        return same and deep_equal(x, value)
    if op == "!=":
        return not (same and deep_equal(x, value))
    if not same or rx >= 4:
        return False
    if rx == 0:
        return op in ("<=", ">=")
    if op == "<":
        return x < value
    if op == "<=":
        return x <= value
    if op == ">":
        return x > value
    return x >= value


def evaluate(pred: Predicate, doc: Any) -> bool:
    """Whether a document satisfies a predicate."""
    t = type(pred)
    if t is Cmp:
        x = get_path(doc, pred.segs)
        return x is not MISSING and compare(x, pred.op, pred.value)
    if t is And:
        return evaluate(pred.left, doc) and evaluate(pred.right, doc)
    if t is Or:
        return evaluate(pred.left, doc) or evaluate(pred.right, doc)
    if t is Not:
        return not evaluate(pred.operand, doc)
    if t is Exists:
        return get_path(doc, pred.segs) is not MISSING
    return get_path(doc, pred.segs) is MISSING


class Plan(NamedTuple):
    """How ``find`` will run: ``kind`` is ``"scan"`` or ``"index"``."""
    kind: str
    path: str = ""            # index path text, for an index plan
    op: str = ""              # the chosen leaf's operator
    prefix: bytes = b""       # V = vkey(value) of the chosen leaf

    def __str__(self) -> str:
        return "scan" if self.kind == "scan" else "index " + self.path


SCAN = Plan("scan")


def _leaves(pred: Predicate) -> list[Predicate]:
    """Flatten ``and`` nodes into their leaves, left to right (SPEC §17.3 step 1)."""
    out: list[Predicate] = []
    stack = [pred]
    while stack:
        p = stack.pop()
        if type(p) is And:
            stack.append(p.right)
            stack.append(p.left)
        else:
            out.append(p)
    return out


def choose_plan(pred: Predicate, index_paths: Sequence[str]) -> Plan:
    """Pick the plan for ``pred`` given the live index path texts (SPEC §17.3)."""
    live = set(index_paths)
    best = None
    for pos, leaf in enumerate(_leaves(pred)):
        if type(leaf) is not Cmp or leaf.op == "!=":
            continue
        v = vkey(leaf.value)
        path = ".".join(leaf.segs)
        if v is None or path not in live:
            continue
        rankkey = (leaf.op != "==", path.encode("utf-8"), pos)
        if best is None or rankkey < best[0]:
            best = (rankkey, Plan("index", path, leaf.op, v))
    return best[1] if best else SCAN


def candidate_bounds(plan: Plan) -> tuple[bytes | None, "callable"]:
    """Where to start walking an index, and when a key is past the candidate range.

    Returns ``(lower, accept)``: ``lower`` is the first index key to seek to
    (``None`` for the start of the tree) and ``accept(key)`` is a function
    returning ``True`` (candidate), ``False`` (skip, but keep walking) or
    ``None`` (past the end of the range: stop).
    """
    v, op = plan.prefix, plan.op
    if op == "==":
        return v, lambda k: True if k.startswith(v) else None
    if op == "<":
        return None, lambda k: True if k < v else None
    if op == "<=":
        return None, lambda k: True if (k < v or k.startswith(v)) else None
    if op == ">":
        return v, lambda k: False if k.startswith(v) else True
    return v, lambda k: True
