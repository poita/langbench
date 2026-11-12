"""Command-line tool: ``tessera <input dir> <output dir>`` (SPEC §2)."""

from __future__ import annotations

import os
import sys

from .database import Database
from .script import run_script


def _read(path: str) -> bytes | None:
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def main(argv: list[str] | None = None) -> int:
    """Run ``commands.txt`` from the input directory against its database.

    Writes ``results.txt``, ``main.tdb`` and ``main.twal`` into the output
    directory. Returns the process exit status.
    """
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 2:
        print("usage: tessera <input dir> <output dir>", file=sys.stderr)
        return 2
    src, dst = args
    script = _read(os.path.join(src, "commands.txt")) or b""
    db = Database.open(_read(os.path.join(src, "main.tdb")), _read(os.path.join(src, "main.twal")))
    results = run_script(db, script.decode("utf-8", errors="replace"))
    os.makedirs(dst, exist_ok=True)
    with open(os.path.join(dst, "results.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write(results)
    db.save(os.path.join(dst, "main.tdb"), os.path.join(dst, "main.twal"))
    return 0
