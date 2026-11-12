"""Rendering results in the line-oriented output format."""

from __future__ import annotations

from typing import Iterable

from .database import StatementResult
from .values import format_value


def format_results(results: Iterable[StatementResult]) -> str:
    """Render statement results as the CLI prints them.

    A SELECT prints one tab-separated line per row followed by ``-- N rows``;
    a failed statement prints ``error``; other statements print nothing.
    """
    lines: list[str] = []
    for result in results:
        if result.error is not None:
            lines.append("error")
        elif result.rows is not None:
            for row in result.rows:
                lines.append("\t".join([format_value(v) for v in row]))
            lines.append(f"-- {len(result.rows)} rows")
    return "".join(line + "\n" for line in lines)
