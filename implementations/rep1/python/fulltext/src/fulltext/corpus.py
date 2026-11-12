"""Reading the input directory: documents and the queries file."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass

from .analysis import WHITESPACE
from .search import DEFAULT_K

__all__ = ["QueryLine", "load_documents", "parse_queries", "load_queries"]

_K_DIRECTIVE = re.compile(r"%k[ \t]+([0-9]+)[ \t]*")


@dataclass(frozen=True, slots=True)
class QueryLine:
    """A query with its 1-based number and the result limit in force."""

    number: int
    text: str
    k: int


def load_documents(docs_dir: str | os.PathLike[str]) -> dict[str, str]:
    """Read every regular ``*.txt`` file directly inside ``docs_dir``.

    Returns ``{id: text}``; a missing directory gives an empty corpus.
    """
    documents: dict[str, str] = {}
    try:
        entries = list(os.scandir(docs_dir))
    except (FileNotFoundError, NotADirectoryError):
        return documents
    for entry in entries:
        if entry.name.endswith(".txt") and entry.is_file():
            with open(entry.path, "rb") as f:
                data = f.read()
            documents[entry.name[: -len(".txt")]] = data.decode("utf-8", errors="replace")
    return documents


def parse_queries(text: str) -> list[QueryLine]:
    """Parse the contents of ``queries.txt``.

    Blank lines and ``#`` comments are skipped; ``%k N`` sets the result limit
    for the queries after it (initially 10).
    """
    queries: list[QueryLine] = []
    k = DEFAULT_K
    for line in text.split("\n"):
        line = line.strip(WHITESPACE)
        if not line or line.startswith("#"):
            continue
        directive = _K_DIRECTIVE.fullmatch(line)
        if directive:
            k = int(directive.group(1))
            continue
        queries.append(QueryLine(len(queries) + 1, line, k))
    return queries


def load_queries(path: str | os.PathLike[str]) -> list[QueryLine]:
    """Read and parse a queries file."""
    with open(path, "rb") as f:
        return parse_queries(f.read().decode("utf-8", errors="replace"))
