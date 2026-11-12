"""Ranked search: ties the query, matching, scoring and snippet modules together."""

from __future__ import annotations

import heapq
from dataclasses import dataclass

from .index import Index
from .matching import Matcher
from .query import parse_query, positive_atoms
from .scoring import idf, term_score
from .snippets import WINDOW, best_window, collapse_whitespace

__all__ = ["Hit", "Searcher", "DEFAULT_K"]

DEFAULT_K = 10


@dataclass(frozen=True, slots=True)
class Hit:
    """One ranked result."""

    rank: int
    doc_id: str
    score: float
    snippet: str


class Searcher:
    """Evaluates queries against an :class:`~fulltext.index.Index`."""

    def __init__(self, index: Index) -> None:
        self.index = index

    def search(self, query: str, k: int = DEFAULT_K) -> list[Hit]:
        """Return the top ``k`` documents for ``query``, best first.

        Scores are BM25 (k1 = 1.2, b = 0.75); ties are broken by document id.
        """
        index = self.index
        tree = parse_query(query)
        if tree is None:
            return []
        matcher = Matcher(index)
        matched = matcher.evaluate(tree)
        if not matched:
            return []

        atoms = positive_atoms(tree)
        n_docs = index.num_documents
        avgdl = index.avgdl
        lengths = index.doc_lengths
        per_atom = []
        for atom in atoms:
            occ = matcher.occurrences(atom)
            per_atom.append((occ, idf(n_docs, len(occ))))

        scored = []
        for doc in matched:
            score = 0.0
            length = lengths[doc]
            for occ, idf_value in per_atom:
                positions = occ.get(doc)
                if positions:
                    score += term_score(idf_value, len(positions), length, avgdl)
            scored.append((-score, doc))
        # Document numbers follow id order, so (-score, number) is the ranking.
        top = heapq.nsmallest(k, scored)

        hits = []
        for rank, (neg_score, doc) in enumerate(top, start=1):
            snippet = self._snippet(doc, atoms, matcher)
            hits.append(Hit(rank, index.doc_ids[doc], -neg_score + 0.0, snippet))
        return hits

    def _snippet(self, doc: int, atoms, matcher: Matcher) -> str:
        index = self.index
        length = index.doc_lengths[doc]
        if length == 0:
            return ""
        occurrences = []
        for atom in atoms:
            positions = matcher.occurrences(atom).get(doc)
            if positions:
                occurrences.append((len(atom.terms), positions))
        start = best_window(length, occurrences, WINDOW)
        stop = min(start + WINDOW, length) - 1
        starts, ends = index.token_spans(doc)
        text = index.texts[doc][starts[start] : ends[stop]]
        return collapse_whitespace(text)
