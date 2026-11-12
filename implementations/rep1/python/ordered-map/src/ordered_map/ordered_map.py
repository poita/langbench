"""The :class:`OrderedMap` class: an AVL tree with order statistics."""

from __future__ import annotations

from collections.abc import Iterator

from .node import NIL, Node, rebalance


class OrderedMap:
    """Ordered map from integer keys to string values.

    Backed by a hand-written AVL tree whose nodes carry subtree sizes, so every
    point operation (insert, delete, get, floor, ceil, successor, predecessor,
    rank, select) costs O(log n) and :meth:`range` costs O(log n + r).

    Python integers are unbounded, so extreme keys never overflow.
    """

    __slots__ = ("_root",)

    def __init__(self) -> None:
        self._root: Node = NIL

    # -- basic container protocol -------------------------------------------

    def __len__(self) -> int:
        return self._root.size

    def __contains__(self, key: object) -> bool:
        return self._find(key) is not NIL  # type: ignore[arg-type]

    def __iter__(self) -> Iterator[int]:
        return self.range(None, None)

    def __repr__(self) -> str:
        return f"OrderedMap({{{', '.join(f'{k!r}: {v!r}' for k, v in self.items())}}})"

    def items(self) -> Iterator[tuple[int, str]]:
        """Iterate over ``(key, value)`` pairs in ascending key order."""
        stack: list[Node] = []
        node = self._root
        while stack or node is not NIL:
            while node is not NIL:
                stack.append(node)
                node = node.left
            node = stack.pop()
            yield node.key, node.value
            node = node.right

    def _find(self, key: int) -> Node:
        node = self._root
        while node is not NIL:
            nk = node.key
            if key < nk:
                node = node.left
            elif key > nk:
                node = node.right
            else:
                return node
        return NIL

    # -- mutation -------------------------------------------------------------

    def insert(self, key: int, value: str) -> bool:
        """Associate ``value`` with ``key``.

        Returns ``True`` if the key was new, ``False`` if an existing value was
        replaced.
        """
        # Fast path: replace an existing value without touching the structure.
        existing = self._find(key)
        if existing is not NIL:
            existing.value = value
            return False
        self._root = self._insert(self._root, key, value)
        return True

    def _insert(self, node: Node, key: int, value: str) -> Node:
        if node is NIL:
            return Node(key, value)
        if key < node.key:
            node.left = self._insert(node.left, key, value)
        else:
            node.right = self._insert(node.right, key, value)
        return rebalance(node)

    def delete(self, key: int) -> bool:
        """Remove ``key``.  Returns ``True`` if it was present."""
        if self._find(key) is NIL:
            return False
        self._root = self._delete(self._root, key)
        return True

    def _delete(self, node: Node, key: int) -> Node:
        # The key is known to be present in this subtree.
        if key < node.key:
            node.left = self._delete(node.left, key)
        elif key > node.key:
            node.right = self._delete(node.right, key)
        else:
            if node.left is NIL:
                return node.right
            if node.right is NIL:
                return node.left
            # Two children: replace with the in-order successor.
            succ = node.right
            while succ.left is not NIL:
                succ = succ.left
            node.key, node.value = succ.key, succ.value
            node.right = self._delete(node.right, succ.key)
        return rebalance(node)

    # -- point queries --------------------------------------------------------

    def get(self, key: int, default: str | None = None) -> str | None:
        """Return the value stored under ``key``, or ``default``."""
        node = self._find(key)
        return default if node is NIL else node.value

    def __getitem__(self, key: int) -> str:
        node = self._find(key)
        if node is NIL:
            raise KeyError(key)
        return node.value

    def __setitem__(self, key: int, value: str) -> None:
        self.insert(key, value)

    def __delitem__(self, key: int) -> None:
        if not self.delete(key):
            raise KeyError(key)

    def min(self) -> int | None:
        """Smallest key, or ``None`` if the map is empty."""
        node = self._root
        if node is NIL:
            return None
        while node.left is not NIL:
            node = node.left
        return node.key

    def max(self) -> int | None:
        """Largest key, or ``None`` if the map is empty."""
        node = self._root
        if node is NIL:
            return None
        while node.right is not NIL:
            node = node.right
        return node.key

    def floor(self, key: int) -> int | None:
        """Largest key ``<= key``, or ``None``."""
        node, best = self._root, None
        while node is not NIL:
            nk = node.key
            if nk == key:
                return nk
            if nk < key:
                best = nk
                node = node.right
            else:
                node = node.left
        return best

    def ceil(self, key: int) -> int | None:
        """Smallest key ``>= key``, or ``None``."""
        node, best = self._root, None
        while node is not NIL:
            nk = node.key
            if nk == key:
                return nk
            if nk > key:
                best = nk
                node = node.left
            else:
                node = node.right
        return best

    def successor(self, key: int) -> int | None:
        """Smallest key strictly greater than ``key``, or ``None``."""
        node, best = self._root, None
        while node is not NIL:
            if node.key > key:
                best = node.key
                node = node.left
            else:
                node = node.right
        return best

    def predecessor(self, key: int) -> int | None:
        """Largest key strictly less than ``key``, or ``None``."""
        node, best = self._root, None
        while node is not NIL:
            if node.key < key:
                best = node.key
                node = node.right
            else:
                node = node.left
        return best

    def rank(self, key: int) -> int:
        """Number of stored keys strictly less than ``key``."""
        node, count = self._root, 0
        while node is not NIL:
            if key <= node.key:
                node = node.left
            else:
                count += node.left.size + 1
                node = node.right
        return count

    def select(self, k: int) -> int | None:
        """The ``k``-th smallest key (0-based), or ``None`` if ``k >= len``."""
        if k < 0 or k >= self._root.size:
            return None
        node = self._root
        while True:
            left = node.left.size
            if k < left:
                node = node.left
            elif k == left:
                return node.key
            else:
                k -= left + 1
                node = node.right

    # -- range ----------------------------------------------------------------

    def range(self, lo: int | None, hi: int | None) -> Iterator[int]:
        """Yield keys ``x`` with ``lo <= x <= hi`` in ascending order.

        ``None`` leaves that side unbounded.  One pruned in-order traversal:
        O(log n + r) for r keys produced.
        """
        stack: list[Node] = []
        node = self._root
        # Descend to the first key >= lo, remembering the ancestors still owed.
        while node is not NIL:
            if lo is None or node.key >= lo:
                stack.append(node)
                node = node.left
            else:
                node = node.right
        while stack:
            node = stack.pop()
            if hi is not None and node.key > hi:
                return
            yield node.key
            node = node.right
            while node is not NIL:
                stack.append(node)
                node = node.left

    # -- diagnostics ----------------------------------------------------------

    def check_invariants(self) -> None:
        """Raise ``AssertionError`` if the tree is malformed (for tests)."""

        def walk(node: Node, lo: int | None, hi: int | None) -> tuple[int, int]:
            if node is NIL:
                return 0, 0
            assert lo is None or node.key > lo, "BST order violated"
            assert hi is None or node.key < hi, "BST order violated"
            lh, ls = walk(node.left, lo, node.key)
            rh, rs = walk(node.right, node.key, hi)
            assert abs(lh - rh) <= 1, "AVL balance violated"
            assert node.height == max(lh, rh) + 1, "stale height"
            assert node.size == ls + rs + 1, "stale size"
            return node.height, node.size

        walk(self._root, None, None)
