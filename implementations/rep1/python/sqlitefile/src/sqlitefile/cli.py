"""Command-line interface: ``python -m sqlitefile <input dir> <output dir>``."""

from __future__ import annotations

import sys
from collections.abc import Sequence
from pathlib import Path

from .engine import Database
from .errors import SqliteFileError

USAGE = "usage: sqlitefile <input directory> <output directory>"


def read_queries(path: Path) -> list[str]:
    """Split ``queries.txt`` into query lines (LF only; the last may lack one)."""
    text = path.read_bytes().decode("utf-8", "surrogateescape")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def find_database(input_dir: Path) -> Path | None:
    """The single ``*.sqlite`` file in ``input_dir``."""
    found = sorted(p for p in input_dir.iterdir() if p.name.endswith(".sqlite"))
    return found[0] if found else None


def run(input_dir: Path, output_dir: Path) -> None:
    """Answer every query in ``input_dir/queries.txt`` into ``output_dir/NNN.txt``."""
    queries = read_queries(input_dir / "queries.txt")
    db_path = find_database(input_dir)
    db: Database | None = None
    if db_path is not None:
        try:
            db = Database.open(db_path)
        except (SqliteFileError, OSError) as exc:
            print(f"sqlitefile: {db_path.name}: {exc}", file=sys.stderr)
    for n, line in enumerate(queries, 1):
        try:
            if db is None:
                raise SqliteFileError("no readable database")
            out = "".join(f"{row}\n" for row in db.run(line))
        except Exception as exc:  # exit status is 0 even when a query fails
            if not isinstance(exc, SqliteFileError):
                print(f"sqlitefile: query {n}: internal error: {exc!r}", file=sys.stderr)
            out = "error\n"
        (output_dir / f"{n:03d}.txt").write_bytes(out.encode("utf-8", "surrogateescape"))


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 2:
        print(USAGE, file=sys.stderr)
        return 2
    run(Path(args[0]), Path(args[1]))
    return 0
