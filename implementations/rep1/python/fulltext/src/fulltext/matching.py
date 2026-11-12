"""Atom matching (positional phrase intersection) and boolean evaluation."""

from __future__ import annotations

from .index import Index
from .query import And, Atom, Node, Not, Or

__all__ = ["Matcher"]

Occurrences = dict[int, list[int]]


class Matcher:
    """Matches atoms and query trees against an index.

    Each distinct atom is matched once; the result is cached for the lifetime
    of the matcher, so create one matcher per query.
    """

    def __init__(self, index: Index) -> None:
        self.index = index
        self._cache: dict[tuple[str, ...], Occurrences] = {}

    def occurrences(self, atom: Atom) -> Occurrences:
        """Map document number -> sorted start positions of ``atom``."""
        result = self._cache.get(atom.terms)
        if result is None:
            result = self._match(atom.terms)
            self._cache[atom.terms] = result
        return result

    def _match(self, terms: tuple[str, ...]) -> Occurrences:
        postings = self.index.postings
        lists = []
        for term in terms:
            entry = postings.get(term)
            if entry is None:
                return {}
            lists.append(entry)
        if len(lists) == 1:
            return lists[0]
        # Candidate documents: those containing every term (scan the smallest).
        smallest = min(lists, key=len)
        result: Occurrences = {}
        for doc in smallest:
            if all(doc in entry for entry in lists):
                starts = _phrase_starts([entry[doc] for entry in lists])
                if starts:
                    result[doc] = starts
        return result

    def evaluate(self, node: Node | None) -> set[int]:
        """The set of document numbers matched by a tree (empty tree: none)."""
        if node is None:
            return set()
        return self._eval(node)

    def _eval(self, node: Node) -> set[int]:
        if isinstance(node, Atom):
            return set(self.occurrences(node))
        if isinstance(node, And):
            result = self._eval(node.children[0])
            for child in node.children[1:]:
                if not result:
                    break
                result &= self._eval(child)
            return result
        if isinstance(node, Or):
            result = self._eval(node.children[0])
            for child in node.children[1:]:
                result |= self._eval(child)
            return result
        inner = self._eval(node.child)
        if node.count % 2 == 0:
            return inner
        return set(range(self.index.num_documents)) - inner


def _phrase_starts(position_lists: list[list[int]]) -> list[int]:
    """Start positions ``p`` where list ``i`` contains ``p + i`` for every ``i``.

    Linear in the total length of the lists: one merge pass per term.
    """
    starts = position_lists[0]
    for offset in range(1, len(position_lists)):
        other = position_lists[offset]
        kept = []
        j, m = 0, len(other)
        for p in starts:
            target = p + offset
            while j < m and other[j] < target:
                j += 1
            if j == m:
                break
            if other[j] == target:
                kept.append(p)
        if not kept:
            return kept
        starts = kept
    return starts
