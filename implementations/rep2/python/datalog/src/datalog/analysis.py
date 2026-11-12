"""Static checks: rule safety and stratification."""

from __future__ import annotations

from .errors import StratificationError, UnsafeRuleError
from .syntax import Comparison, Literal, Program, Rule, Signature, Variable


def check_safety(program: Program) -> None:
    """Raise :class:`UnsafeRuleError` unless every rule is safe.

    A rule is safe when each variable of its head, of its negated atoms and
    of its comparisons also occurs in a positive body atom.
    """
    for rule in program.rules:
        check_rule_safety(rule)


def check_rule_safety(rule: Rule) -> None:
    bound: set[Variable] = set()
    for item in rule.body:
        if isinstance(item, Literal) and not item.negated:
            bound.update(item.atom.variables())
    needing = list(rule.head.variables())
    for item in rule.body:
        if isinstance(item, Literal):
            if item.negated:
                needing.extend(item.atom.variables())
        else:
            needing.extend(item.variables())
    for var in needing:
        if var not in bound:
            raise UnsafeRuleError(f"unsafe rule for {rule.head.predicate}/{len(rule.head.args)}: "
                                  f"variable {var.name} is not bound by a positive body atom")


def stratify(program: Program) -> list[list[Signature]]:
    """Group the predicates of ``program`` into strongly connected components
    of the dependency graph, ordered so that every component comes after the
    components it depends on.

    Raises :class:`StratificationError` if a negative dependency lies inside a
    component (a cycle through negation).
    """
    # deps[p] = predicates that p's rules read.  Insertion order = first use.
    deps: dict[Signature, dict[Signature, None]] = {}
    negative: list[tuple[Signature, Signature]] = []
    for rule in program.rules:
        head = rule.head.signature
        edges = deps.setdefault(head, {})
        for item in rule.body:
            if isinstance(item, Literal):
                sig = item.atom.signature
                edges[sig] = None
                deps.setdefault(sig, {})
                if item.negated:
                    negative.append((head, sig))

    components = _tarjan(deps)
    where = {sig: i for i, comp in enumerate(components) for sig in comp}
    for head, sig in negative:
        if where[head] == where[sig]:
            raise StratificationError(
                f"{head[0]}/{head[1]} depends on itself through negation of {sig[0]}/{sig[1]}")
    return components


def _tarjan(graph: dict[Signature, dict[Signature, None]]) -> list[list[Signature]]:
    """Tarjan's SCC algorithm (iterative).  Components are emitted after every
    component reachable from them, i.e. dependencies first."""
    index: dict[Signature, int] = {}
    low: dict[Signature, int] = {}
    on_stack: set[Signature] = set()
    stack: list[Signature] = []
    result: list[list[Signature]] = []
    counter = 0

    for root in graph:
        if root in index:
            continue
        index[root] = low[root] = counter
        counter += 1
        stack.append(root)
        on_stack.add(root)
        work = [(root, iter(graph[root]))]
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
                result.append(comp)
    return result
