"""Stream processing: run a whole command stream through an order book."""

from __future__ import annotations

from collections.abc import Iterable, Iterator
from typing import Optional

from .book import OrderBook
from .commands import parse_command


def parse_stream(text: str) -> Iterator[str]:
    """Yield the command lines of an input document.

    The first line is the command count ``N``; exactly ``N`` command lines
    follow.
    """
    lines = text.split("\n")
    n = int(lines[0]) if lines and lines[0].strip() else 0
    return iter(lines[1 : n + 1])


def process(
    lines: Iterable[str], book: Optional[OrderBook] = None
) -> Iterator[str]:
    """Execute each command line and yield the output lines it produces."""
    if book is None:
        book = OrderBook()
    execute = book.execute
    for line in lines:
        for event in execute(parse_command(line)):
            yield str(event)


def run(text: str) -> str:
    """Process a full input document and return the full output text."""
    out = "\n".join(process(parse_stream(text)))
    return out + "\n" if out else ""
