"""Stratified semi-naive bottom-up evaluation."""

from __future__ import annotations

from collections import defaultdict
from typing import Iterable

from .analysis import check_safety, stratify
from .codegen import compile_plan
from .constants import ConstantTable
from .parser import parse_atom
from .planner import plan_rule, positive_atoms
from .relation import Relation, Row
from .syntax import (
    Atom, Comparison, Const, ConstantValue, Literal, Not, PredicateKey,
    Program, Query, Rule, Var,
)


def _constants(program: Program) -> Iterable[ConstantValue]:
    atoms: list[Atom] = [q.atom for q in program.queries]
    for rule in program.rules:
        atoms.append(rule.head)
        for lit in rule.body:
            if isinstance(lit, Atom):
                atoms.append(lit)
            elif isinstance(lit, Not):
                atoms.append(lit.atom)
            else:
                yield from (t.value for t in (lit.left, lit.right) if isinstance(t, Const))
    for atom in atoms:
        yield from (t.value for t in atom.args if isinstance(t, Const))


def _encode_atom(atom: Atom, table: ConstantTable) -> Atom:
    return Atom(atom.pred, tuple(Const(table.encode(t.value)) if isinstance(t, Const) else t
                                 for t in atom.args))


def _encode_rule(rule: Rule, table: ConstantTable) -> Rule:
    def term(t):
        return Const(table.encode(t.value)) if isinstance(t, Const) else t

    body: list[Literal] = []
    for lit in rule.body:
        if isinstance(lit, Atom):
            body.append(_encode_atom(lit, table))
        elif isinstance(lit, Not):
            body.append(Not(_encode_atom(lit.atom, table)))
        else:
            body.append(Comparison(lit.op, term(lit.left), term(lit.right)))
    return Rule(_encode_atom(rule.head, table), tuple(body))


class Model:
    """The perfect model of a program, ready to answer queries."""

    def __init__(self, relations: dict[PredicateKey, Relation], table: ConstantTable) -> None:
        self._relations = relations
        self._table = table

    def predicates(self) -> list[PredicateKey]:
        """All predicates (name, arity) of the program, sorted."""
        return sorted(self._relations)

    def relation(self, name: str, arity: int) -> list[tuple[ConstantValue, ...]]:
        """All tuples of ``name/arity`` in ascending order (empty if unknown)."""
        rel = self._relations.get((name, arity))
        if rel is None:
            return []
        return [self._decode(r) for r in sorted(rel.tuples)]

    def query(self, atom: Atom | Query | str) -> list[tuple[ConstantValue, ...]]:
        """Tuples matching a query pattern, in ascending order.

        ``atom`` may be an :class:`Atom`, a :class:`Query` or text such as
        ``"path(1, X)"``.  Constants equal the tuple's value, a variable that
        repeats must match the same value at each position, ``_`` matches
        anything.
        """
        if isinstance(atom, str):
            atom = parse_atom(atom)
        elif isinstance(atom, Query):
            atom = atom.atom
        rel = self._relations.get(atom.key)
        if rel is None:
            return []
        positions: list[int] = []
        key: list[int] = []
        first_seen: dict[str, int] = {}
        equal: list[tuple[int, int]] = []
        for pos, t in enumerate(atom.args):
            if isinstance(t, Const):
                rank = self._table.get(t.value)
                if rank is None:
                    return []
                positions.append(pos)
                key.append(rank)
            elif t.name in first_seen:
                equal.append((first_seen[t.name], pos))
            else:
                first_seen[t.name] = pos
        rows = rel.lookup(tuple(positions), key[0] if len(key) == 1 else tuple(key))
        if equal:
            rows = [r for r in rows if all(r[i] == r[j] for i, j in equal)]
        return [self._decode(r) for r in sorted(rows)]

    def _decode(self, row: Row) -> tuple[ConstantValue, ...]:
        decode = self._table.decode
        return tuple(decode(v) for v in row)


def evaluate(program: Program) -> Model:
    """Check ``program`` and compute its stratified model.

    Raises :class:`~datalog.errors.UnsafeRuleError` or
    :class:`~datalog.errors.StratificationError`.
    """
    check_safety(program.rules)
    components = stratify(program.rules)

    table = ConstantTable(_constants(program))
    rules = [_encode_rule(r, table) for r in program.rules]
    relations = _RelationMap()

    rules_by_head: dict[PredicateKey, list[Rule]] = defaultdict(list)
    for rule in rules:
        if rule.body:
            rules_by_head[rule.head.key].append(rule)
        else:  # a ground fact
            relations[rule.head.key].add_all(
                [tuple(t.value for t in rule.head.args)])  # type: ignore[attr-defined]
    for q in program.queries:
        relations[q.atom.key]

    for component in components:
        _evaluate_component(component, rules_by_head, relations)
    return Model(dict(relations), table)


class _RelationMap(dict):
    """Dict of relations that creates an empty relation on first access."""

    def __missing__(self, key: PredicateKey) -> Relation:
        rel = self[key] = Relation(*key)
        return rel


def _evaluate_component(component: tuple[PredicateKey, ...],
                        rules_by_head: dict[PredicateKey, list[Rule]],
                        relations: _RelationMap) -> None:
    members = set(component)
    base = []        # compiled plans without an in-component positive atom
    recursive = []   # (compiled delta plan, delta predicate, head predicate)
    for pred in component:
        for rule in rules_by_head.get(pred, ()):
            atoms = positive_atoms(rule)
            rec_positions = [i for i, a in enumerate(atoms) if a.key in members]
            if not rec_positions:
                base.append((compile_plan(plan_rule(rule), relations), pred))
            for i in rec_positions:
                fn = compile_plan(plan_rule(rule, i), relations)
                recursive.append((fn, atoms[i].key, pred))

    # Round 0: rules that do not read the component's own predicates.
    new: dict[PredicateKey, set[Row]] = {p: set() for p in component}
    for fn, head in base:
        fn(new[head])
    for pred in component:
        relations[pred].add_all(new[pred])
    if not recursive:
        return

    # Later rounds: each recursive atom in turn reads last round's new tuples.
    delta = {p: list(relations[p].tuples) for p in component}
    while any(delta.values()):
        new = {p: set() for p in component}
        for fn, source, head in recursive:
            if delta[source]:
                fn(delta[source], new[head])
        delta = {p: relations[p].add_all(new[p]) for p in component}
