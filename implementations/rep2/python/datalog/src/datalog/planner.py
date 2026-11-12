"""Compilation of rules into join plans.

A rule (whose constants are already encoded as integers) is compiled into a
Python function ``plan(delta, new)``.  It performs an indexed nested-loop join
over the positive body atoms, applying negated atoms (membership tests on
complete relations) and comparisons as soon as their variables are bound, and
adds each head tuple not already in the head relation to the set ``new``.

When the plan is a *delta variant* one positive atom (the delta atom) is read
from the iterable ``delta`` (the tuples new in the previous round) and is
joined first; every other atom reads its full relation.  The join order is
that atom first, then repeatedly the atom with the most bound arguments
(constants or already bound variables), ties going to body order.

The loop nest is generated as Python source and compiled with ``exec``: that
removes all interpretive overhead from the inner loops, which matters when a
program derives millions of tuples.
"""

from __future__ import annotations

from collections import Counter
from typing import Callable, Iterable, Sequence

from .relation import Database
from .syntax import Atom, Comparison, Literal, Rule, Term, Variable

Plan = Callable[[Iterable[tuple], set], None]

_PY_OPS = {"<": "<", "<=": "<=", ">": ">", ">=": ">=", "=": "==", "!=": "!="}

# Generated sources are identical for structurally identical rules; share the
# compiled code objects between them.
_code_cache: dict[str, object] = {}


def join_order(atoms: Sequence[Atom], first: int | None = None) -> list[int]:
    """Order in which to join ``atoms`` (indices into the sequence)."""
    order: list[int] = []
    remaining = list(range(len(atoms)))
    bound: set[Variable] = set()

    def take(i: int) -> None:
        remaining.remove(i)
        order.append(i)
        bound.update(atoms[i].variables())

    if first is not None:
        take(first)
    while remaining:
        best = max(
            remaining,
            key=lambda i: (
                sum(1 for a in atoms[i].args if not isinstance(a, Variable) or a in bound),
                -i,
            ),
        )
        take(best)
    return order


def compile_rule(rule: Rule, delta_atom: int | None, db: Database) -> Plan:
    """Compile ``rule`` into a plan.

    ``delta_atom`` is the index, among the rule's positive body atoms, of the
    atom to read from the delta, or ``None`` to read every atom from the full
    relations.  ``db`` supplies (and receives) the relations and indexes.
    """
    return _PlanBuilder(rule, delta_atom, db).build()


class _PlanBuilder:
    def __init__(self, rule: Rule, delta_atom: int | None, db: Database) -> None:
        self.rule = rule
        self.delta_atom = delta_atom
        self.db = db
        self.positives = [i.atom for i in rule.body if isinstance(i, Literal) and not i.negated]
        # Filters not yet emitted: negated atoms and comparisons.
        self.pending: list[Literal | Comparison] = [
            i for i in rule.body if isinstance(i, Comparison) or i.negated
        ]
        # Variables occurring only once in the whole rule never need a name.
        self.uses: Counter[Variable] = Counter(rule.head.variables())
        for item in rule.body:
            self.uses.update(item.atom.variables() if isinstance(item, Literal) else item.variables())
        self.namespace: dict[str, object] = {}
        self.names: dict[Variable, str] = {}
        self.lines: list[str] = ["def plan(delta, new):"]
        self.depth = 1  # indentation level
        self.loops = 0  # number of loops currently open

    # -- helpers ---------------------------------------------------------
    def emit(self, text: str) -> None:
        self.lines.append("    " * self.depth + text)

    def bind_object(self, prefix: str, obj: object) -> str:
        name = f"{prefix}{len(self.namespace)}"
        self.namespace[name] = obj
        return name

    def expr(self, term: Term) -> str:
        return self.names[term] if isinstance(term, Variable) else repr(term)

    def tuple_expr(self, terms: Sequence[Term]) -> str:
        parts = [self.expr(t) for t in terms]
        return "(" + ", ".join(parts) + ("," if len(parts) == 1 else "") + ")"

    def is_bound(self, term: Term) -> bool:
        return not isinstance(term, Variable) or term in self.names

    @property
    def skip(self) -> str:
        return "continue" if self.loops else "return"

    # -- generation ------------------------------------------------------
    def build(self) -> Plan:
        self.emit_filters()
        order = join_order(self.positives, self.delta_atom)
        for step, i in enumerate(order):
            self.emit_atom(self.positives[i], from_delta=(step == 0 and self.delta_atom is not None))
            self.emit_filters()
        assert not self.pending, "unsafe rule reached the planner"
        head = self.rule.head
        full = self.bind_object("full", self.db.relation(head.predicate, len(head.args)).tuples)
        self.emit(f"row = {self.tuple_expr(head.args)}")
        self.emit(f"if row not in {full}:")
        self.emit("    new.add(row)")
        source = "\n".join(self.lines)
        code = _code_cache.get(source)
        if code is None:
            code = _code_cache[source] = compile(source, "<datalog-plan>", "exec")
        exec(code, self.namespace)
        return self.namespace["plan"]  # type: ignore[return-value]

    def emit_filters(self) -> None:
        still: list[Literal | Comparison] = []
        for item in self.pending:
            if isinstance(item, Comparison):
                if all(self.is_bound(t) for t in (item.left, item.right)):
                    op = _PY_OPS[item.op]
                    self.emit(f"if not ({self.expr(item.left)} {op} {self.expr(item.right)}): {self.skip}")
                else:
                    still.append(item)
            else:
                atom = item.atom
                if all(self.is_bound(t) for t in atom.args):
                    rel = self.db.relation(atom.predicate, len(atom.args)).tuples
                    name = self.bind_object("neg", rel)
                    self.emit(f"if {self.tuple_expr(atom.args)} in {name}: {self.skip}")
                else:
                    still.append(item)
        self.pending = still

    def emit_atom(self, atom: Atom, from_delta: bool) -> None:
        rel = self.db.relation(atom.predicate, len(atom.args))
        row = f"t{self.loops}"
        args = atom.args
        key_positions = () if from_delta else tuple(j for j, a in enumerate(args) if self.is_bound(a))
        if len(key_positions) == len(args):
            # Fully bound: a membership test, no new variables.
            rel_name = self.bind_object("rel", rel.tuples)
            self.emit(f"if {self.tuple_expr(args)} not in {rel_name}: {self.skip}")
            return
        if from_delta:
            source = "delta"
        elif not key_positions:
            source = self.bind_object("rel", rel.tuples)
        else:
            table = self.bind_object("idx", rel.index(key_positions))
            key = [self.expr(args[j]) for j in key_positions]
            source = f"{table}.get({key[0] if len(key) == 1 else '(' + ', '.join(key) + ')'}, ())"
        self.emit(f"for {row} in {source}:")
        self.depth += 1
        self.loops += 1
        keyed = set(key_positions)
        for j, arg in enumerate(args):
            if j in keyed:
                continue
            if not isinstance(arg, Variable):
                self.emit(f"if {row}[{j}] != {arg!r}: continue")
            elif arg in self.names:
                self.emit(f"if {row}[{j}] != {self.names[arg]}: continue")
            elif self.uses[arg] > 1:
                name = f"v{len(self.names)}"
                self.names[arg] = name
                self.emit(f"{name} = {row}[{j}]")
