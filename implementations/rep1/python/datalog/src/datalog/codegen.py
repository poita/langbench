"""Compile a join :class:`~datalog.planner.Plan` into a Python function.

Each plan becomes a stack of nested ``for`` loops over index buckets (or the
delta), with ``if`` guards for checks, negations and comparisons -- an indexed
nested-loop join specialised to the rule, without per-tuple interpretation
overhead.  The generated function has the signature ``run(delta, out)`` for
delta plans and ``run(out)`` otherwise, and adds every derived head tuple that
is not yet in the head relation to the set ``out``.
"""

from __future__ import annotations

from collections import Counter
from typing import Callable, Mapping

from .planner import Plan
from .relation import Relation
from .syntax import Atom, Comparison, Const, Literal, Not, PredicateKey, Term, Var

_PY_OP = {"<": "<", "<=": "<=", ">": ">", ">=": ">=", "=": "==", "!=": "!="}


def _tuple_src(parts: list[str]) -> str:
    return "(" + ", ".join(parts) + ("," if len(parts) == 1 else "") + ")"


def compile_plan(plan: Plan, relations: Mapping[PredicateKey, Relation]) -> Callable:
    """Generate and return the ``run`` function for ``plan``.

    Indexes the plan needs are requested from the relations now (and are then
    kept up to date by the relations themselves).
    """
    rule = plan.rule
    ns: dict[str, object] = {}
    lines: list[str] = []
    depth = 1
    uid = 0

    # A variable seen once in the whole rule is a wildcard: never bound.
    occurrences: Counter[str] = Counter()
    for lit in (rule.head, *rule.body):
        atom = lit.atom if isinstance(lit, Not) else lit
        terms = (atom.left, atom.right) if isinstance(atom, Comparison) else atom.args
        occurrences.update(t.name for t in terms if isinstance(t, Var))

    def emit(text: str) -> None:
        lines.append("    " * depth + text)

    def term(t: Term) -> str:
        return repr(t.value) if isinstance(t, Const) else f"v_{t.name}"

    def bind(name: str, obj: object) -> str:
        nonlocal uid
        uid += 1
        key = f"{name}{uid}"
        ns[key] = obj
        return key

    def emit_filters(filters: tuple[Literal, ...]) -> None:
        nonlocal depth
        for f in filters:
            if isinstance(f, Comparison):
                emit(f"if {term(f.left)} {_PY_OP[f.op]} {term(f.right)}:")
            else:
                rel = relations[f.atom.key]
                row = _tuple_src([term(t) for t in f.atom.args])
                emit(f"if {row} not in {bind('N', rel.tuples)}:")
            depth += 1

    bound: set[str] = set()
    emit_filters(plan.pre)
    for step, atom_idx in enumerate(plan.order):
        atom = plan.atoms[atom_idx]
        rel = relations[atom.key]
        is_delta = plan.delta and step == 0

        bound_pos: list[int] = []
        key_terms: list[Term] = []
        targets: list[str] = []          # loop-unpacking names, one per position
        checks: list[str] = []           # extra equality guards
        new_here: set[str] = set()
        for pos, t in enumerate(atom.args):
            if isinstance(t, Const) or t.name in bound:
                bound_pos.append(pos)
                key_terms.append(t)
                if is_delta:   # the delta is not indexed: test the value
                    tmp = f"b{step}_{pos}"
                    targets.append(tmp)
                    checks.append(f"{tmp} == {term(t)}")
                else:
                    targets.append("_")
            elif t.name in new_here:   # repeated variable within the atom
                tmp = f"b{step}_{pos}"
                targets.append(tmp)
                checks.append(f"{tmp} == {term(t)}")
            elif occurrences[t.name] == 1:
                targets.append("_")
            else:
                new_here.add(t.name)
                targets.append(term(t))

        if is_delta:
            emit(f"for {_tuple_src(targets)} in delta:")
            depth += 1
        elif len(bound_pos) == len(atom.args):      # fully bound: membership
            row = _tuple_src([term(t) for t in atom.args])
            emit(f"if {row} in {bind('S', rel.tuples)}:")
            depth += 1
        else:
            if bound_pos:
                idx = bind("I", rel.index(tuple(bound_pos)))
                key = (term(key_terms[0]) if len(key_terms) == 1
                       else _tuple_src([term(t) for t in key_terms]))
                if all(n == "_" for n in targets) and not checks:
                    emit(f"if {key} in {idx}:")    # pure existence test
                    depth += 1
                    src = None
                else:
                    src = f"{idx}.get({key}, ())"
            else:
                src = bind("R", rel.tuples)
            if src is not None:
                emit(f"for {_tuple_src(targets)} in {src}:")
                depth += 1
        for c in checks:
            emit(f"if {c}:")
            depth += 1
        bound |= new_here
        emit_filters(plan.after[step])

    head = rule.head
    emit(f"h = {_tuple_src([term(t) for t in head.args])}")
    emit(f"if h not in {bind('H', relations[head.key].tuples)}:")
    depth += 1
    emit("out.add(h)")

    header = "def run(delta, out):" if plan.delta else "def run(out):"
    source = header + "\n" + "\n".join(lines) + "\n"
    exec(compile(source, f"<plan {rule}>", "exec"), ns)
    fn = ns["run"]
    fn.__source__ = source  # type: ignore[attr-defined]  # handy when debugging
    return fn  # type: ignore[return-value]
