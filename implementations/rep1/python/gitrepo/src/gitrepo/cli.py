"""Command-line interface.

Usage: ``python -m gitrepo <input path> <output dir>``

``<input path>`` holds ``repo/`` (a git directory) and ``commands.txt``; for
command *k* the file ``<output dir>/NNN.out`` is written.
"""

from __future__ import annotations

import os
import sys

from .commands import ERROR_OUTPUT, run_command
from .repository import Repository


def run(input_dir: str, output_dir: str) -> None:
    """Run every command in ``<input_dir>/commands.txt`` against ``<input_dir>/repo``."""
    with open(os.path.join(input_dir, "commands.txt"), "rb") as f:
        lines = f.read().split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    os.makedirs(output_dir, exist_ok=True)
    repo = Repository(os.path.join(input_dir, "repo"))
    for k, line in enumerate(lines, 1):
        try:
            result = run_command(repo, line)
        except Exception:  # a query must never crash the run
            result = ERROR_OUTPUT
        with open(os.path.join(output_dir, f"{k:03d}.out"), "wb") as out:
            out.write(result)


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 2:
        print("usage: gitrepo <input path> <output dir>", file=sys.stderr)
        return 2
    run(args[0], args[1])
    return 0
