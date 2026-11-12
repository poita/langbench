"""Indexed binary max-heap keyed by an external activity array."""

from __future__ import annotations

from typing import List


class ActivityHeap:
    """Max-heap of variable indices ordered by ``activity[var]``.

    The heap shares the ``activity`` list with its owner, so after the owner
    *increases* ``activity[v]`` it must call :meth:`increased`. ``pos`` maps a
    variable to its heap slot, or ``-1`` when absent, so membership tests,
    inserts and key increases are O(1) / O(log n).
    """

    __slots__ = ("activity", "heap", "pos")

    def __init__(self, activity: List[float]) -> None:
        self.activity = activity
        self.heap: List[int] = []
        self.pos: List[int] = [-1] * len(activity)

    def grow(self, n: int) -> None:
        """Make room for variables up to ``n - 1`` (``activity`` already grown)."""
        if len(self.pos) < n:
            self.pos.extend([-1] * (n - len(self.pos)))

    def __len__(self) -> int:
        return len(self.heap)

    def __contains__(self, var: int) -> bool:
        return self.pos[var] >= 0

    def insert(self, var: int) -> None:
        """Insert ``var`` if it is not already present."""
        if self.pos[var] >= 0:
            return
        heap = self.heap
        self.pos[var] = len(heap)
        heap.append(var)
        self._up(len(heap) - 1)

    def increased(self, var: int) -> None:
        """Restore the heap property after ``activity[var]`` increased."""
        i = self.pos[var]
        if i >= 0:
            self._up(i)

    def pop_max(self) -> int:
        """Remove and return the variable of highest activity."""
        heap = self.heap
        pos = self.pos
        top = heap[0]
        last = heap.pop()
        pos[top] = -1
        if heap:
            heap[0] = last
            pos[last] = 0
            self._down(0)
        return top

    def rebuild(self, variables) -> None:
        """Replace the contents by ``variables`` and heapify."""
        for v in self.heap:
            self.pos[v] = -1
        self.heap = list(variables)
        for i, v in enumerate(self.heap):
            self.pos[v] = i
        for i in range(len(self.heap) // 2 - 1, -1, -1):
            self._down(i)

    def _up(self, i: int) -> None:
        heap, pos, act = self.heap, self.pos, self.activity
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
        heap, pos, act = self.heap, self.pos, self.activity
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
