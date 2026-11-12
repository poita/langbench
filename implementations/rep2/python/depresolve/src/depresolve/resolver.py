"""The resolution search.

The search is the specified depth-first, newest-first, chronologically
backtracking procedure, run iteratively (no recursion limit) over integer-
indexed data:

* every package gets an id; its versions are stored oldest first and a
  requirement becomes ``(package id, lo, hi)``, the half-open index range of
  the versions it admits (found once, by binary search);
* the pending requirements are an immutable cons list ``(pkg, lo, hi, next)``
  shared between choice points, so a choice point never copies them;
* each choice point is one entry on a stack of parallel lists, which doubles
  as the trail: popping it undoes the package's choice.
"""

from __future__ import annotations

from bisect import bisect_left
from collections.abc import Sequence

from .registry import Registry, Requirement
from .version import Version


class _Compiled:
    """Integer-indexed form of a registry and root manifest."""

    def __init__(self, registry: Registry, root: Sequence[Requirement]) -> None:
        self.names: list[str] = []
        ids: dict[str, int] = {}
        for name in registry.packages:
            ids[name] = len(self.names)
            self.names.append(name)
        for req in (*root, *(r for vs in registry.packages.values() for rs in vs.values() for r in rs)):
            if req.name not in ids:
                ids[req.name] = len(self.names)
                self.names.append(req.name)

        # Versions ascending per package (aligned with ``deps``).
        self.versions: list[list[Version]] = [[] for _ in self.names]
        self.deps: list[list[tuple[tuple[int, int, int], ...]]] = [[] for _ in self.names]
        sorted_versions = [sorted(registry.packages.get(n, ())) for n in self.names]
        span_cache: dict[tuple[int, object], tuple[int, int]] = {}

        def compile_req(req: Requirement) -> tuple[int, int, int]:
            pid = ids[req.name]
            key = (pid, req.range)
            span = span_cache.get(key)
            if span is None:
                vs = sorted_versions[pid]
                rng = req.range
                lo = bisect_left(vs, rng.lo)
                hi = len(vs) if rng.hi is None else bisect_left(vs, rng.hi)
                span = span_cache[key] = (lo, max(lo, hi))
            return (pid, span[0], span[1])

        for pid, name in enumerate(self.names):
            self.versions[pid] = sorted_versions[pid]
            table = registry.packages.get(name, {})
            # Stored reversed so that prepending them to the pending list in
            # a loop leaves the first requirement in front.
            self.deps[pid] = [
                tuple(compile_req(r) for r in reversed(table[v])) for v in sorted_versions[pid]
            ]
        self.root = tuple(compile_req(r) for r in reversed(root))


def resolve(
    registry: Registry, root: Sequence[Requirement]
) -> dict[str, Version] | None:
    """Resolve ``root`` against ``registry``.

    Returns the chosen version of every needed package (the first solution in
    depth-first, newest-first, chronologically backtracking order), or
    ``None`` when no resolution exists.
    """
    c = _Compiled(registry, root)
    deps = c.deps
    chosen = [-1] * len(c.names)

    pending = None
    for p, lo, hi in c.root:
        pending = (p, lo, hi, pending)

    # Choice-point stack: package, current candidate index, lowest admissible
    # index, and the pending requirements it continues with.
    st_pkg: list[int] = []
    st_idx: list[int] = []
    st_lo: list[int] = []
    st_rest: list = []

    while pending is not None:
        pkg, lo, hi, nxt = pending
        cur = chosen[pkg]
        if cur >= 0:
            if lo <= cur < hi:
                pending = nxt
                continue
        elif lo < hi:
            idx = hi - 1
            chosen[pkg] = idx
            st_pkg.append(pkg)
            st_idx.append(idx)
            st_lo.append(lo)
            st_rest.append(nxt)
            pending = nxt
            for p, l, h in deps[pkg][idx]:
                pending = (p, l, h, pending)
            continue
        # Failure: move the most recent choice point with candidates left.
        while True:
            if not st_pkg:
                return None
            pkg = st_pkg[-1]
            idx = st_idx[-1] - 1
            if idx >= st_lo[-1]:
                break
            chosen[pkg] = -1
            st_pkg.pop()
            st_idx.pop()
            st_lo.pop()
            st_rest.pop()
        st_idx[-1] = idx
        chosen[pkg] = idx
        pending = st_rest[-1]
        for p, l, h in deps[pkg][idx]:
            pending = (p, l, h, pending)

    return {
        c.names[pid]: c.versions[pid][idx] for pid, idx in enumerate(chosen) if idx >= 0
    }


def format_resolution(resolution: dict[str, Version] | None) -> str:
    """Render a result as the CLI prints it: ``name version`` lines sorted by
    name, or ``unsatisfiable``."""
    if resolution is None:
        return "unsatisfiable\n"
    return "".join(f"{n} {resolution[n]}\n" for n in sorted(resolution))
