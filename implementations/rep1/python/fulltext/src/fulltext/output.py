"""Formatting of ``results.txt`` and ``stats.txt``."""

from __future__ import annotations

from collections.abc import Iterable

from .index import Index
from .search import Hit

__all__ = ["format_results", "format_stats"]


def format_results(blocks: Iterable[tuple[int, str, list[Hit]]]) -> str:
    """Render ``(number, query text, hits)`` blocks as ``results.txt``."""
    lines: list[str] = []
    for number, text, hits in blocks:
        lines.append(f"QUERY {number} {text}")
        lines.append(f"HITS {len(hits)}")
        for hit in hits:
            lines.append(f"{hit.rank}\t{hit.doc_id}\t{hit.score:.4f}\t{hit.snippet}")
    return "".join(line + "\n" for line in lines)


def format_stats(index: Index) -> str:
    """Render the four-line ``stats.txt``."""
    return (
        f"documents {index.num_documents}\n"
        f"tokens {index.total_tokens}\n"
        f"terms {index.num_terms}\n"
        f"avgdl {index.avgdl:.4f}\n"
    )
