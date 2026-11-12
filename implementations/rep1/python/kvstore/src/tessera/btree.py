"""B+tree search, insert, delete, rebalance and scans over canonical pages (SPEC §12)."""

from __future__ import annotations

from bisect import bisect_left
from typing import Any, Callable, Iterator

from .constants import CAPACITY, MIN_FILL, PAGE_INTERIOR
from .pages import Node, decode, empty_leaf, encode, split_point
from .pager import Pager


class BTree:
    """One B+tree (the primary tree, or the tree of one secondary index).

    ``leaf_type`` selects the cell format of the leaves (``PAGE_LEAF`` or
    ``PAGE_INDEX_LEAF``). The root page number lives outside the tree, in the
    header page; ``get_root`` / ``set_root`` read and write it.
    """

    def __init__(self, pager: Pager, leaf_type: int,
                 get_root: Callable[[], int], set_root: Callable[[int], None]):
        self.pager = pager
        self.leaf_type = leaf_type
        self.get_root = get_root
        self.set_root = set_root

    # -- page access -----------------------------------------------------------------

    def _load(self, page_no: int) -> Node:
        return decode(page_no, self.pager.read(page_no))

    def _store(self, node: Node) -> None:
        self.pager.write(node.page_no, encode(node))

    @staticmethod
    def _child(node: Node, i: int) -> int:
        return node.vals[i] if i < len(node.keys) else node.link

    # -- search ----------------------------------------------------------------------

    def _descend(self, key: bytes) -> tuple[Node, list[tuple[Node, int]]] | None:
        root = self.get_root()
        if root == 0:
            return None
        node = self._load(root)
        path: list[tuple[Node, int]] = []
        while node.type == PAGE_INTERIOR:
            i = bisect_left(node.keys, key)
            path.append((node, i))
            node = self._load(self._child(node, i))
        return node, path

    def get(self, key: bytes) -> Any | None:
        """The value stored under ``key``, or ``None`` (primary trees only store non-None values)."""
        found = self._descend(key)
        if found is None:
            return None
        leaf = found[0]
        i = bisect_left(leaf.keys, key)
        if i < len(leaf.keys) and leaf.keys[i] == key:
            return leaf.vals[i]
        return None

    # -- insert / replace --------------------------------------------------------------

    def insert(self, key: bytes, val: Any) -> bool:
        """Insert ``(key, val)``, or replace the cell in place. Returns True if replaced."""
        pager = self.pager
        if self.get_root() == 0:
            root = pager.allocate()
            pager.write(root, encode(empty_leaf(root, self.leaf_type)))
            self.set_root(root)
        leaf, path = self._descend(key)
        i = bisect_left(leaf.keys, key)
        replaced = i < len(leaf.keys) and leaf.keys[i] == key
        if replaced:
            leaf.vals[i] = val
        else:
            leaf.keys.insert(i, key)
            leaf.vals.insert(i, val)
        self._store_or_split(leaf, path)
        return replaced

    def _store_or_split(self, node: Node, path: list[tuple[Node, int]]) -> None:
        """Store ``node``; while it overflows, split it and install the separator above."""
        pager = self.pager
        while True:
            costs = node.costs()
            if sum(costs) <= CAPACITY:
                self._store(node)
                return
            m = split_point(costs)
            right_no = pager.allocate()
            if node.is_leaf:
                right = Node(right_no, node.type, node.keys[m:], node.vals[m:], node.link)
                sep = node.keys[m - 1]
                del node.keys[m:], node.vals[m:]
                node.link = right_no
            else:
                right = Node(right_no, node.type, node.keys[m:], node.vals[m:], node.link)
                sep = node.keys[m - 1]
                node.link = node.vals[m - 1]
                del node.keys[m - 1:], node.vals[m - 1:]
            self._store(right)
            self._store(node)
            if not path:
                new_root = pager.allocate()
                self._store(Node(new_root, PAGE_INTERIOR, [sep], [node.page_no], right_no))
                self.set_root(new_root)
                return
            parent, j = path.pop()
            if j == len(parent.keys):
                parent.keys.append(sep)
                parent.vals.append(node.page_no)
                parent.link = right_no
            else:
                parent.vals[j] = right_no
                parent.keys.insert(j, sep)
                parent.vals.insert(j, node.page_no)
            node = parent

    # -- delete ------------------------------------------------------------------------

    def delete(self, key: bytes) -> bool:
        """Remove ``key``; returns False (and changes nothing) when it is absent."""
        found = self._descend(key)
        if found is None:
            return False
        leaf, path = found
        i = bisect_left(leaf.keys, key)
        if i >= len(leaf.keys) or leaf.keys[i] != key:
            return False
        del leaf.keys[i], leaf.vals[i]
        if not path:
            if leaf.keys:
                self._store(leaf)
            else:
                self.pager.free(leaf.page_no)
                self.set_root(0)
            return True
        if leaf.used() >= MIN_FILL:
            self._store(leaf)
            return True
        self._rebalance(leaf, path)
        return True

    def _rebalance(self, n: Node, path: list[tuple[Node, int]]) -> None:
        """SPEC §12.5: borrow left, borrow right, merge left, merge right."""
        pager = self.pager
        while True:
            parent, j = path.pop()
            nk = len(parent.keys)
            left = self._load(parent.vals[j - 1]) if j >= 1 else None
            right = self._load(self._child(parent, j + 1)) if j < nk else None
            leaf = n.is_leaf

            if left is not None and left.used() - left.costs()[-1] >= MIN_FILL:
                if leaf:
                    n.keys.insert(0, left.keys.pop())
                    n.vals.insert(0, left.vals.pop())
                    parent.keys[j - 1] = left.keys[-1]
                else:
                    n.keys.insert(0, parent.keys[j - 1])
                    n.vals.insert(0, left.link)
                    parent.keys[j - 1] = left.keys.pop()
                    left.link = left.vals.pop()
                self._store(left)
                self._store(n)
                self._store_or_split(parent, path)
                return

            if right is not None and right.used() - right.costs()[0] >= MIN_FILL:
                if leaf:
                    n.keys.append(right.keys.pop(0))
                    n.vals.append(right.vals.pop(0))
                    parent.keys[j] = n.keys[-1]
                else:
                    n.keys.append(parent.keys[j])
                    n.vals.append(n.link)
                    n.link = right.vals.pop(0)
                    parent.keys[j] = right.keys.pop(0)
                self._store(right)
                self._store(n)
                self._store_or_split(parent, path)
                return

            if left is not None:
                if not leaf:
                    left.keys.append(parent.keys[j - 1])
                    left.vals.append(left.link)
                left.keys.extend(n.keys)
                left.vals.extend(n.vals)
                left.link = n.link
                del parent.keys[j - 1], parent.vals[j - 1]
                if j == nk:
                    parent.link = left.page_no
                else:
                    parent.vals[j - 1] = left.page_no
                self._store(left)
                pager.free(n.page_no)
            else:
                if not leaf:
                    n.keys.append(parent.keys[j])
                    n.vals.append(n.link)
                n.keys.extend(right.keys)
                n.vals.extend(right.vals)
                n.link = right.link
                del parent.keys[j], parent.vals[j]
                if j + 1 == nk:
                    parent.link = n.page_no
                else:
                    parent.vals[j] = n.page_no
                self._store(n)
                pager.free(right.page_no)

            # A merge removed a cell from the parent.
            if not path:
                if not parent.keys:
                    self.set_root(parent.link)
                    pager.free(parent.page_no)
                else:
                    self._store(parent)
                return
            if parent.used() >= MIN_FILL:
                self._store(parent)
                return
            n = parent

    # -- traversal ---------------------------------------------------------------------

    def iter_from(self, lower: bytes | None = None) -> Iterator[tuple[bytes, Any]]:
        """Cells in ascending key order, starting at the first key ``>= lower``."""
        root = self.get_root()
        if root == 0:
            return
        node = self._load(root)
        while node.type == PAGE_INTERIOR:
            i = 0 if lower is None else bisect_left(node.keys, lower)
            node = self._load(self._child(node, i))
        i = 0 if lower is None else bisect_left(node.keys, lower)
        while True:
            keys, vals = node.keys, node.vals
            for idx in range(i, len(keys)):
                yield keys[idx], vals[idx]
            if not node.link:
                return
            node = self._load(node.link)
            i = 0

    def iter_reverse(self, upper: bytes | None = None) -> Iterator[tuple[bytes, Any]]:
        """Cells in descending key order, starting at the last key ``< upper``."""
        root = self.get_root()
        if root == 0:
            return
        stack: list[tuple[Node, int]] = []
        node = self._load(root)
        while node.type == PAGE_INTERIOR:
            i = len(node.keys) if upper is None else bisect_left(node.keys, upper)
            stack.append((node, i))
            node = self._load(self._child(node, i))
        pos = len(node.keys) if upper is None else bisect_left(node.keys, upper)
        while True:
            for idx in range(pos - 1, -1, -1):
                yield node.keys[idx], node.vals[idx]
            while stack and stack[-1][1] == 0:
                stack.pop()
            if not stack:
                return
            parent, i = stack.pop()
            i -= 1
            stack.append((parent, i))
            node = self._load(self._child(parent, i))
            while node.type == PAGE_INTERIOR:
                stack.append((node, len(node.keys)))
                node = self._load(node.link)
            pos = len(node.keys)

    def pages_post_order(self) -> list[int]:
        """Every page of the tree in post-order (children left to right, then the page)."""
        root = self.get_root()
        out: list[int] = []
        if root == 0:
            return out
        stack: list[tuple[Node, int]] = [(self._load(root), 0)]
        while stack:
            node, i = stack.pop()
            if node.type != PAGE_INTERIOR or i > len(node.keys):
                out.append(node.page_no)
                continue
            stack.append((node, i + 1))
            stack.append((self._load(self._child(node, i)), 0))
        return out

    def height(self) -> int:
        """0 for an empty tree, 1 when the root is a leaf, and so on (SPEC §12.7)."""
        root = self.get_root()
        if root == 0:
            return 0
        h = 1
        node = self._load(root)
        while node.type == PAGE_INTERIOR:
            h += 1
            node = self._load(self._child(node, 0))
        return h
