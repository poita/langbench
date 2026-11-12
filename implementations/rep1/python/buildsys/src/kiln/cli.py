"""Command-line interface: ``kiln <input directory> <output directory>``."""

from __future__ import annotations

import os
import sys
import threading
from collections.abc import Sequence

from .session import run_session
from .vfs import VirtualFS

USAGE = "usage: kiln <input directory> <output directory>"


def run(input_dir: str, output_dir: str) -> None:
    """Run the session in *input_dir*, writing ``log.txt`` and ``workspace/``."""
    with open(os.path.join(input_dir, "session.txt"), "rb") as fh:
        session = fh.read()
    vfs = VirtualFS.load(input_dir)
    log = run_session(vfs, session)
    os.makedirs(output_dir, exist_ok=True)
    with open(os.path.join(output_dir, "log.txt"), "wb") as fh:
        fh.write(log)
    workspace = os.path.join(output_dir, "workspace")
    os.makedirs(workspace, exist_ok=True)
    vfs.dump(workspace)


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point; returns the process exit status."""
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 2:
        print(USAGE, file=sys.stderr)
        return 2
    # Deeply nested expressions recurse; give the interpreter room to do so.
    sys.setrecursionlimit(200_000)
    for size in (512, 128, 32):
        try:
            threading.stack_size(size * 1024 * 1024)
            break
        except (ValueError, RuntimeError):
            continue
    status: list[int] = [0]

    def target() -> None:
        try:
            run(args[0], args[1])
        except Exception as exc:  # report, but never leave a traceback-only failure silent
            print(f"kiln: {exc!r}", file=sys.stderr)
            status[0] = 1

    thread = threading.Thread(target=target)
    thread.start()
    thread.join()
    return status[0]
