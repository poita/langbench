"""Exact distance tables, filled by breadth-first search from the goal."""

from __future__ import annotations

from .coords import CoordinateSpace

UNREACHED = 255


def build_distance_table(space: CoordinateSpace) -> bytearray:
    """BFS over ``space`` from its goal; ``table[s]`` = moves needed to reach it.

    The move sets are closed under inversion, so distance *from* the goal equals
    distance *to* it.  Unreachable coordinate values stay :data:`UNREACHED`.
    """
    nb = space.nb
    dist = bytearray([UNREACHED]) * space.size
    dist[space.goal] = 0
    frontier = [space.goal]
    pairs = list(zip(space.a_tables, space.b_tables))
    depth = 0
    while frontier:
        depth += 1
        nxt = []
        append = nxt.append
        for s in frontier:
            a = s // nb
            b = s - a * nb
            for ta, tb in pairs:
                n = ta[a] + tb[b]
                if dist[n] == UNREACHED:
                    dist[n] = depth
                    append(n)
        frontier = nxt
    return dist
