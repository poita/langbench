"""BM25 scoring."""

from __future__ import annotations

from math import log

__all__ = ["K1", "B", "idf", "term_score"]

K1 = 1.2
B = 0.75


def idf(num_documents: int, df: int) -> float:
    """Inverse document frequency; always positive."""
    return log((num_documents - df + 0.5) / (df + 0.5) + 1)


def term_score(idf_value: float, freq: int, doc_length: int, avgdl: float) -> float:
    """One atom's BM25 contribution to a document."""
    ratio = doc_length / avgdl if avgdl else 0.0
    return idf_value * (freq * (K1 + 1)) / (freq + K1 * (1 - B + B * ratio))
