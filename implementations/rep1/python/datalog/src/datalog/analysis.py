"""Static checks: rule safety and stratification."""

from __future__ import annotations

from typing import Iterable, Sequence

from .errors import StratificationError, UnsafeRuleError
from .syntax import Atom, Comparison, Not, PredicateKey, Rule


def is_safe(rule: Rule) -> bool:
    """A rule is safe when every variable in its head, in a negated atom or
    in a comparison also occurs in a positive body atom."""
    positive: set[str] = set()
    for lit in rule.body:
        if isinstance(lit, Atom):
            positive |= lit.variables()
    needed = rule.head.variables()
    for lit in rule.body:
        if isinstance(lit, (Not, Comparison)):
            needed |= lit.variables()
    return needed <= positive


def check_safety(rules: Iterable[Rule]) -> None:
    """Raise :class:`UnsafeRuleError` for the first unsafe rule."""
    for rule in rules:
        if not is_safe(rule):
            raise UnsafeRuleError(f"unsafe rule: {rule}")


def stratify(rules: Sequence[Rule]) -> list[tuple[PredicateKey, ...]]:
    """Group predicates into strongly connected components of the dependency
    graph and return them in evaluation order (dependencies first).

    Raises :class:`StratificationError` if a negative edge lies inside a
    component, i.e. some predicate depends negatively on itself.
    """
    # Edge head -> dependency, so Tarjan emits dependencies before dependents.
    deps: dict[PredicateKey, list[PredicateKey]] = {}
    negative: list[tuple[PredicateKey, PredicateKey]] = []
    for rule in rules:
        head = rule.head.key
        out = deps.setdefault(head, [])
        for lit in rule.body:
            if isinstance(lit, Atom):
                out.append(lit.key)
                deps.setdefault(lit.key, [])
            elif isinstance(lit, Not):
                out.append(lit.atom.key)
                deps.setdefault(lit.atom.key, [])
                negative.append((head, lit.atom.key))

    components = _tarjan(deps)
    comp_of = {p: n for n, comp in enumerate(components) for p in comp}
    for head, dep in negative:
        if comp_of[head] == comp_of[dep]:
            raise StratificationError(
                f"{head[0]}/{head[1]} depends negatively on "
                f"{dep[0]}/{dep[1]} within a cycle"
            )
    return components


def _tarjan(graph: dict[PredicateKey, list[PredicateKey]]) -> list[tuple[PredicateKey, ...]]:
    """Iterative Tarjan SCC.  Components come out in reverse topological order
    of the given graph (every successor component is emitted first)."""
    index: dict[PredicateKey, int] = {}
    low: dict[PredicateKey, int] = {}
    on_stack: set[PredicateKey] = set()
    stack: list[PredicateKey] = []
    result: list[tuple[PredicateKey, ...]] = []
    counter = 0

    for root in graph:
        if root in index:
            continue
        work = [(root, iter(graph[root]))]
        index[root] = low[root] = counter
        counter += 1
        stack.append(root)
        on_stack.add(root)
        while work:
            node, it = work[-1]
            advanced = False
            for succ in it:
                if succ not in index:
                    index[succ] = low[succ] = counter
                    counter += 1
                    stack.append(succ)
                    on_stack.add(succ)
                    work.append((succ, iter(graph[succ])))
                    advanced = True
                    break
                if succ in on_stack:
                    low[node] = min(low[node], index[succ])
            if advanced:
                continue
            work.pop()
            if work:
                parent = work[-1][0]
                low[parent] = min(low[parent], low[node])
            if low[node] == index[node]:
                comp = []
                while True:
                    member = stack.pop()
                    on_stack.discard(member)
                    comp.append(member)
                    if member == node:
                        break
                result.append(tuple(comp))
    return result
