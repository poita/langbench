"""Indexed binary max-heap keyed by an external activity array."""

from __future__ import annotations

from typing import List


class VarHeap:
    """Max-heap of variable indices ordered by ``activity[v]``.

    ``activity`` is shared with (and mutated by) the owner; after raising
    ``activity[v]`` call :meth:`increased`. Supports O(log n) insert, pop and
    key increase, and O(1) membership.
    """

    __slots__ = ("act", "heap", "pos")

    def __init__(self, activity: List[float]) -> None:
        self.act = activity
        self.heap: List[int] = []
        self.pos: List[int] = [-1] * len(activity)

    def __len__(self) -> int:
        return len(self.heap)

    def __contains__(self, v: int) -> bool:
        return self.pos[v] >= 0

    def insert(self, v: int) -> None:
        if self.pos[v] >= 0:
            return
        self.pos[v] = len(self.heap)
        self.heap.append(v)
        self._up(self.pos[v])

    def increased(self, v: int) -> None:
        """Restore heap order after ``activity[v]`` grew (no-op if absent)."""
        i = self.pos[v]
        if i >= 0:
            self._up(i)

    def pop(self) -> int:
        """Remove and return the variable of highest activity."""
        heap, pos = self.heap, self.pos
        top = heap[0]
        last = heap.pop()
        pos[top] = -1
        if heap:
            heap[0] = last
            pos[last] = 0
            self._down(0)
        return top

    def _up(self, i: int) -> None:
        heap, pos, act = self.heap, self.pos, self.act
        v = heap[i]
        a = act[v]
        while i > 0:
            parent = (i - 1) >> 1
            pv = heap[parent]
            if act[pv] >= a:
                break
            heap[i] = pv
            pos[pv] = i
            i = parent
        heap[i] = v
        pos[v] = i

    def _down(self, i: int) -> None:
        heap, pos, act = self.heap, self.pos, self.act
        n = len(heap)
        v = heap[i]
        a = act[v]
        while True:
            child = 2 * i + 1
            if child >= n:
                break
            if child + 1 < n and act[heap[child + 1]] > act[heap[child]]:
                child += 1
            cv = heap[child]
            if act[cv] <= a:
                break
            heap[i] = cv
            pos[cv] = i
            i = child
        heap[i] = v
        pos[v] = i
