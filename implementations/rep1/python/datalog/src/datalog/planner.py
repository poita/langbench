"""Join planning: choose the order in which a rule's literals are evaluated."""

from __future__ import annotations

from dataclasses import dataclass

from .syntax import Atom, Comparison, Const, Literal, Not, Rule, Var


@dataclass(frozen=True, slots=True)
class Plan:
    """An evaluation order for one rule (or one delta variant of it).

    ``atoms``
        the positive body atoms in source order;
    ``order``
        indices into ``atoms`` in join order;
    ``pre``
        filters (negations / comparisons) that need no variables;
    ``after``
        ``after[k]`` are the filters to apply once ``order[:k+1]`` are bound;
    ``delta``
        whether the first atom of ``order`` is read from the delta of the
        previous round instead of from the whole relation.
    """

    rule: Rule
    atoms: tuple[Atom, ...]
    order: tuple[int, ...]
    pre: tuple[Literal, ...]
    after: tuple[tuple[Literal, ...], ...]
    delta: bool

    @property
    def delta_atom(self) -> Atom | None:
        return self.atoms[self.order[0]] if self.delta else None


def positive_atoms(rule: Rule) -> tuple[Atom, ...]:
    return tuple(l for l in rule.body if isinstance(l, Atom))


def _bound_count(atom: Atom, bound: set[str]) -> int:
    return sum(isinstance(t, Const) or t.name in bound for t in atom.args)


def plan_rule(rule: Rule, delta_index: int | None = None) -> Plan:
    """Plan ``rule``.

    With ``delta_index`` (an index into the positive atoms) that atom is the
    delta atom and is joined first.  Afterwards the atom with the most bound
    arguments (constants or already bound variables) is joined next, ties
    going to the earliest atom in the body.
    """
    atoms = positive_atoms(rule)
    remaining = list(range(len(atoms)))
    order: list[int] = []
    bound: set[str] = set()

    if delta_index is not None:
        order.append(delta_index)
        remaining.remove(delta_index)
        bound |= atoms[delta_index].variables()
    while remaining:
        best = max(remaining, key=lambda i: (_bound_count(atoms[i], bound), -i))
        order.append(best)
        remaining.remove(best)
        bound |= atoms[best].variables()

    # Place each filter right after the first step that binds all its variables.
    filters = [l for l in rule.body if isinstance(l, (Not, Comparison))]
    pre: list[Literal] = []
    after: list[list[Literal]] = [[] for _ in order]
    for f in filters:
        needed = f.variables()
        if not needed:
            pre.append(f)
            continue
        seen: set[str] = set()
        for k, i in enumerate(order):
            seen |= atoms[i].variables()
            if needed <= seen:
                after[k].append(f)
                break
        else:  # unsafe rule; analysis.check_safety must run first
            raise ValueError(f"cannot place filter {f} in {rule}")
    return Plan(rule, atoms, tuple(order), tuple(pre),
                tuple(tuple(a) for a in after), delta_index is not None)
