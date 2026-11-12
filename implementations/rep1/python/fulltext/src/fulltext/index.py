"""The positional inverted index."""

from __future__ import annotations

from array import array
from collections.abc import Mapping

from .analysis import TOKEN_RE, fold, term_for, token_spans

__all__ = ["Index"]


class Index:
    """A positional inverted index over a corpus of documents.

    Documents are numbered ``0 .. N-1`` in order of their id (Unicode code
    point order), so comparing document numbers is the same as comparing ids.

    Attributes:
        doc_ids: the document ids, sorted.
        doc_lengths: number of tokens (stop words included) of each document.
        texts: the original text of each document.
        postings: term -> {document number -> sorted list of positions}.
        total_tokens: sum of all document lengths.
    """

    def __init__(self, documents: Mapping[str, str] | None = None) -> None:
        documents = documents or {}
        self.doc_ids: list[str] = sorted(documents)
        self.texts: list[str] = [documents[d] for d in self.doc_ids]
        self.doc_lengths: list[int] = []
        self.postings: dict[str, dict[int, list[int]]] = {}
        self.total_tokens = 0
        self._spans: dict[int, tuple[array, array]] = {}
        for number, text in enumerate(self.texts):
            self._add_document(number, text)

    def _add_document(self, number: int, text: str) -> None:
        local: dict[str, list[int]] = {}
        length = 0
        for position, raw in enumerate(TOKEN_RE.findall(text)):
            term = term_for(fold(raw))
            positions = local.get(term)
            if positions is None:
                local[term] = [position]
            else:
                positions.append(position)
            length = position + 1
        postings = self.postings
        for term, positions in local.items():
            entry = postings.get(term)
            if entry is None:
                postings[term] = {number: positions}
            else:
                entry[number] = positions
        self.doc_lengths.append(length)
        self.total_tokens += length

    @property
    def num_documents(self) -> int:
        """``N``, the number of documents."""
        return len(self.doc_ids)

    @property
    def num_terms(self) -> int:
        """The number of distinct terms (stop-word terms included)."""
        return len(self.postings)

    @property
    def avgdl(self) -> float:
        """The mean document length; 0 for an empty corpus."""
        n = len(self.doc_ids)
        return self.total_tokens / n if n else 0.0

    def token_spans(self, number: int) -> tuple[array, array]:
        """Character spans ``(starts, ends)`` of the tokens of a document."""
        spans = self._spans.get(number)
        if spans is None:
            spans = token_spans(self.texts[number])
            self._spans[number] = spans
        return spans
