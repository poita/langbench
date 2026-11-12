"""Tree flattening and comparison (``diff``)."""

from __future__ import annotations

from dataclasses import dataclass

from .objects import S_IFDIR, S_IFMT
from .repository import Repository

ZERO_ID = "0" * 40


@dataclass(frozen=True, slots=True)
class Change:
    """One differing path between two trees."""

    path: bytes
    status: str  # A, D, M or T
    old_mode: int
    new_mode: int
    old_id: str
    new_id: str


def flatten(repo: Repository, tree_id: str) -> dict[bytes, tuple[int, str]]:
    """Map every non-tree path under *tree_id* to ``(mode, id)``.

    Every subtree is read, even one shared with another tree.
    """
    result: dict[bytes, tuple[int, str]] = {}
    stack: list[tuple[bytes, str]] = [(b"", tree_id)]
    while stack:
        prefix, oid = stack.pop()
        for entry in repo.tree(oid):
            path = prefix + entry.name
            if entry.mode & S_IFMT == S_IFDIR:
                stack.append((path + b"/", entry.id))
            else:
                result[path] = (entry.mode, entry.id)
    return result


def diff_trees(repo: Repository, old_tree: str, new_tree: str) -> list[Change]:
    """Compare two trees; changes are sorted by path bytes."""
    old = flatten(repo, old_tree)
    new = flatten(repo, new_tree)
    changes: list[Change] = []
    for path in sorted(old.keys() | new.keys()):
        a = old.get(path)
        b = new.get(path)
        if a == b:
            continue
        if a is None:
            changes.append(Change(path, "A", 0, b[0], ZERO_ID, b[1]))
        elif b is None:
            changes.append(Change(path, "D", a[0], 0, a[1], ZERO_ID))
        else:
            status = "M" if a[0] & S_IFMT == b[0] & S_IFMT else "T"
            changes.append(Change(path, status, a[0], b[0], a[1], b[1]))
    return changes
