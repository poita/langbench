"""The depth-first, newest-first, chronologically backtracking resolver.

The search is the one defined in SPEC.md, run with an explicit stack of choice
points so recursion depth is unbounded, and in O(1) per step (plus the
requirements a step adds):

* the pending requirements are an immutable singly linked list of
  ``(requirement, rest)`` pairs, shared between choice points;
* each choice point remembers only ``(package, next candidate, end, rest)``;
* chosen versions live in one array and are undone as choice points pop;
* a requirement's candidates are a precomputed contiguous index range into the
  package's newest-first version list.
"""

from __future__ import annotations

import gc
from bisect import bisect_right
from dataclasses import dataclass
from typing import Iterable

from .model import Registry, Requirement
from .version import Version


@dataclass(frozen=True, slots=True)
class Resolution:
    """A successful resolution: one version per needed package."""

    versions: dict[str, Version]

    def lines(self) -> list[str]:
        """``"name version"`` lines sorted by name in ascending byte order."""
        return [f"{n} {self.versions[n]}" for n in sorted(self.versions)]


def resolve(
    registry: Registry, root: Iterable[Requirement]
) -> Resolution | None:
    """Resolve *root* against *registry*.

    Returns the first solution in the search order of SPEC.md, or ``None`` if
    no resolution exists.
    """
    ids: dict[str, int] = {}
    names: list[str] = []

    def pid_of(name: str) -> int:
        pid = ids.get(name)
        if pid is None:
            pid = ids[name] = len(names)
            names.append(name)
        return pid

    # Per package: versions newest first, plus negated keys (ascending) used to
    # turn a key interval into an index range with binary search.
    versions: list[list[Version]] = []
    neg_keys: list[list[int]] = []
    for name in registry.names():
        pid_of(name)
    for name in names:
        vs = registry.versions(name)
        versions.append(vs)
        neg_keys.append([-v.key for v in vs])

    def compile_req(req: Requirement) -> tuple[int, int, int]:
        pid = pid_of(req.name)
        while pid >= len(neg_keys):  # package absent from the registry
            versions.append([])
            neg_keys.append([])
        keys = neg_keys[pid]
        lo = bisect_right(keys, -req.range.high)
        hi = bisect_right(keys, -req.range.low)
        return (pid, lo, max(lo, hi))

    # table[pid][index] = that version's requirements, compiled and *reversed*
    # so they can be consed onto the pending list in a simple loop.
    table: list[list[tuple[tuple[int, int, int], ...]]] = []
    for pid in range(len(names)):
        name = names[pid]
        table.append(
            [
                tuple(compile_req(r) for r in reversed(registry.requirements(name, v)))
                for v in versions[pid]
            ]
        )
    root_reqs = [compile_req(r) for r in root]
    while len(table) < len(names):
        table.append([])

    chosen = _search(root_reqs, table, len(names))
    if chosen is None:
        return None
    return Resolution(
        {names[p]: versions[p][i] for p, i in enumerate(chosen) if i >= 0}
    )


def _search(
    root_reqs: list[tuple[int, int, int]],
    table: list[list[tuple[tuple[int, int, int], ...]]],
    package_count: int,
) -> list[int] | None:
    """Run the search; return the chosen index per package (-1 = none)."""
    chosen = [-1] * package_count
    pending = None
    for req in reversed(root_reqs):
        pending = (req, pending)
    stack: list[tuple[int, int, int, object]] = []
    push = stack.append
    pop = stack.pop

    gc_was_enabled = gc.isenabled()
    gc.disable()  # the structures here are acyclic; skip pointless collections
    try:
        while pending is not None:
            (pid, lo, hi), rest = pending
            cur = chosen[pid]
            if cur >= 0:
                if lo <= cur < hi:
                    pending = rest
                    continue
            elif lo < hi:
                chosen[pid] = lo
                push((pid, lo + 1, hi, rest))
                pending = rest
                for req in table[pid][lo]:
                    pending = (req, pending)
                continue
            # FAIL: advance the most recent choice point with a candidate left.
            while stack:
                pid, nxt, hi, rest = pop()
                if nxt < hi:
                    push((pid, nxt + 1, hi, rest))
                    chosen[pid] = nxt
                    pending = rest
                    for req in table[pid][nxt]:
                        pending = (req, pending)
                    break
                chosen[pid] = -1
            else:
                return None
    finally:
        if gc_was_enabled:
            gc.enable()
    return chosen
