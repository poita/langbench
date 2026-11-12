"""Semi-naive bottom-up evaluation of stratified Datalog programs."""

from __future__ import annotations

from dataclasses import dataclass

from .analysis import check_safety, stratify
from .planner import compile_rule
from .relation import Database, Relation, Row
from .syntax import (
    Atom,
    Comparison,
    Constant,
    Literal,
    Program,
    Rule,
    Signature,
    Variable,
    constant_key,
)


@dataclass(slots=True)
class Model:
    """The perfect model of a program.

    Internally constants are replaced by their rank in the constant order, so
    that comparisons and sorting are plain integer operations; the model
    translates back and forth at its public boundary.
    """

    _db: Database
    _constants: list[Constant]  # rank -> constant
    _rank: dict[Constant, int]  # constant -> rank

    def relation(self, name: str, arity: int) -> list[tuple[Constant, ...]]:
        """All tuples of ``name/arity``, in ascending tuple order."""
        rel = self._db.get(name, arity)
        if rel is None:
            return []
        return self._decode(sorted(rel.tuples))

    def query(self, atom: Atom) -> list[tuple[Constant, ...]]:
        """The tuples of ``atom``'s relation matching its pattern (constants
        must be equal, a variable repeated in the atom must take one value),
        in ascending tuple order.  ``_``-style single-use variables match
        anything."""
        rel = self._db.get(atom.predicate, len(atom.args))
        if rel is None:
            return []
        const_pos: list[int] = []
        const_val: list[int] = []
        first_seen: dict[Variable, int] = {}
        same: list[tuple[int, int]] = []  # (position, earlier position) pairs
        for j, arg in enumerate(atom.args):
            if isinstance(arg, Variable):
                if arg in first_seen:
                    same.append((j, first_seen[arg]))
                else:
                    first_seen[arg] = j
            else:
                rank = self._rank.get(arg)
                if rank is None:
                    return []  # a constant the program never mentions
                const_pos.append(j)
                const_val.append(rank)
        if const_pos:
            key = const_val[0] if len(const_pos) == 1 else tuple(const_val)
            candidates = rel.index(tuple(const_pos)).get(key, ()) if len(const_pos) < rel.arity \
                else ([tuple(const_val)] if tuple(const_val) in rel.tuples else [])
        else:
            candidates = rel.tuples
        if same:
            matches = [t for t in candidates if all(t[a] == t[b] for a, b in same)]
        else:
            matches = list(candidates)
        matches.sort()
        return self._decode(matches)

    def _decode(self, rows: list[Row]) -> list[tuple[Constant, ...]]:
        c = self._constants
        return [tuple(c[v] for v in row) for row in rows]


def evaluate(program: Program) -> Model:
    """Compute the stratified model of ``program``.

    Raises :class:`~datalog.errors.UnsafeRuleError` or
    :class:`~datalog.errors.StratificationError` if the program is not
    acceptable.
    """
    check_safety(program)
    components = stratify(program)

    constants = sorted(program.constants(), key=constant_key)
    rank = {c: i for i, c in enumerate(constants)}
    db = Database()

    rules = [_encode_rule(r, rank) for r in program.rules]
    facts: dict[Signature, set[Row]] = {}
    by_head: dict[Signature, list[Rule]] = {}
    for rule in rules:
        sig = rule.head.signature
        if rule.is_fact:
            facts.setdefault(sig, set()).add(rule.head.args)  # type: ignore[arg-type]
        else:
            by_head.setdefault(sig, []).append(rule)
    for sig, rows in facts.items():
        db.relation(*sig).add_all(rows)

    for component in components:
        comp_rules = [r for sig in component for r in by_head.get(sig, ())]
        if comp_rules:
            _evaluate_component(set(component), comp_rules, db)
    return Model(db, constants, rank)


def _encode_rule(rule: Rule, rank: dict[Constant, int]) -> Rule:
    def term(t):
        return t if isinstance(t, Variable) else rank[t]

    def atom(a: Atom) -> Atom:
        return Atom(a.predicate, tuple(term(t) for t in a.args))

    body = tuple(
        Literal(atom(i.atom), i.negated) if isinstance(i, Literal)
        else Comparison(i.op, term(i.left), term(i.right))
        for i in rule.body
    )
    return Rule(atom(rule.head), body)


def _evaluate_component(component: set[Signature], rules: list[Rule], db: Database) -> None:
    """Least fixpoint of ``rules`` (all heads in ``component``), semi-naively.

    Negated atoms only mention lower components (checked by ``stratify``), so
    they are complete and act as plain filters.
    """
    # First round: every rule once over the relations as they are.
    new: dict[Signature, set[Row]] = {}
    for rule in rules:
        compile_rule(rule, None, db)(None, new.setdefault(rule.head.signature, set()))
    delta = _commit(new, db)

    # One variant per positive body atom inside the component, reading that
    # atom from the delta.
    variants: list[tuple[Signature, Signature, object]] = []  # (head, delta predicate, plan)
    for rule in rules:
        positives = [i.atom for i in rule.body if isinstance(i, Literal) and not i.negated]
        for k, atom in enumerate(positives):
            if atom.signature in component:
                variants.append((rule.head.signature, atom.signature, compile_rule(rule, k, db)))
    if not variants:
        return

    while delta:
        new = {}
        for head, source, plan in variants:
            rows = delta.get(source)
            if rows:
                plan(rows, new.setdefault(head, set()))  # type: ignore[operator]
        delta = _commit(new, db)


def _commit(new: dict[Signature, set[Row]], db: Database) -> dict[Signature, list[Row]]:
    """Add the round's tuples to their relations; return the genuinely new ones
    per predicate (the next round's delta)."""
    delta: dict[Signature, list[Row]] = {}
    for sig, rows in new.items():
        fresh = db.relation(*sig).add_all(rows)
        if fresh:
            delta[sig] = fresh
    return delta
