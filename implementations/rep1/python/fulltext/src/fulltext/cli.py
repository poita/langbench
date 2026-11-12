"""Command-line interface: ``fulltext <input dir> <output dir>``."""

from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Sequence

from .corpus import load_documents, load_queries
from .index import Index
from .output import format_results, format_stats
from .search import Searcher

__all__ = ["main", "run"]


def run(input_dir: str, output_dir: str) -> None:
    """Index ``<input_dir>/docs``, answer ``<input_dir>/queries.txt`` and write
    ``results.txt`` and ``stats.txt`` into ``output_dir``."""
    index = Index(load_documents(os.path.join(input_dir, "docs")))
    searcher = Searcher(index)
    queries = load_queries(os.path.join(input_dir, "queries.txt"))
    blocks = [(q.number, q.text, searcher.search(q.text, q.k)) for q in queries]

    os.makedirs(output_dir, exist_ok=True)
    for name, content in (
        ("results.txt", format_results(blocks)),
        ("stats.txt", format_stats(index)),
    ):
        with open(os.path.join(output_dir, name), "w", encoding="utf-8", newline="\n") as f:
            f.write(content)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="fulltext",
        description="Index <input>/docs/*.txt, run <input>/queries.txt and write "
        "results.txt and stats.txt to the output directory.",
    )
    parser.add_argument("input_dir", help="directory containing docs/ and queries.txt")
    parser.add_argument("output_dir", help="directory to write results.txt and stats.txt into")
    args = parser.parse_args(argv)
    sys.setrecursionlimit(max(sys.getrecursionlimit(), 10_000))
    run(args.input_dir, args.output_dir)
    return 0
