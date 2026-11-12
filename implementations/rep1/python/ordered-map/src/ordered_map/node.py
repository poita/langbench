"""AVL tree node and the primitive rebalancing operations.

A single shared sentinel, :data:`NIL`, stands in for every empty subtree.  It
has height 0 and size 0, so the balancing code never needs ``None`` checks.
"""

from __future__ import annotations


class Node:
    """A tree node augmented with subtree height and subtree size."""

    __slots__ = ("key", "value", "left", "right", "height", "size")

    def __init__(self, key: int, value: str) -> None:
        self.key = key
        self.value = value
        self.left: Node = NIL
        self.right: Node = NIL
        self.height = 1
        self.size = 1


# The empty-subtree sentinel.  Never mutated.
NIL: Node = Node.__new__(Node)
NIL.key = 0
NIL.value = ""
NIL.left = NIL
NIL.right = NIL
NIL.height = 0
NIL.size = 0


def update(node: Node) -> None:
    """Recompute ``node.height`` and ``node.size`` from its children."""
    left, right = node.left, node.right
    lh, rh = left.height, right.height
    node.height = (lh if lh > rh else rh) + 1
    node.size = left.size + right.size + 1


def rotate_right(node: Node) -> Node:
    """Rotate ``node`` right; return the new subtree root."""
    pivot = node.left
    node.left = pivot.right
    pivot.right = node
    update(node)
    update(pivot)
    return pivot


def rotate_left(node: Node) -> Node:
    """Rotate ``node`` left; return the new subtree root."""
    pivot = node.right
    node.right = pivot.left
    pivot.left = node
    update(node)
    update(pivot)
    return pivot


def rebalance(node: Node) -> Node:
    """Refresh ``node``'s augmentation and restore the AVL invariant.

    Both children must already be valid AVL trees whose heights differ by at
    most two.  Returns the (possibly new) subtree root.
    """
    update(node)
    balance = node.left.height - node.right.height
    if balance > 1:
        if node.left.left.height < node.left.right.height:
            node.left = rotate_left(node.left)
        return rotate_right(node)
    if balance < -1:
        if node.right.right.height < node.right.left.height:
            node.right = rotate_right(node.right)
        return rotate_left(node)
    return node
