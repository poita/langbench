"""Command-line entry point: read the batch format on stdin, write results."""

from __future__ import annotations

import sys
import threading

from .protocol import run

_STACK_BYTES = 256 * 1024 * 1024
_RECURSION_LIMIT = 10_000_000


def _process() -> None:
    text = sys.stdin.buffer.read().decode("latin-1")
    out = sys.stdout
    for chunk in run(text):
        if chunk:
            out.write(chunk)
    out.flush()


def main() -> int:
    """Run the batch processor on a thread with a large stack.

    Deeply nested backtracking recurses a few frames per subject character,
    so the interpreter's recursion limit is raised as well.
    """
    sys.setrecursionlimit(_RECURSION_LIMIT)
    threading.stack_size(_STACK_BYTES)
    errors: list[BaseException] = []

    def target() -> None:
        try:
            _process()
        except BaseException as exc:  # reported below, on the main thread
            errors.append(exc)

    worker = threading.Thread(target=target)
    worker.start()
    worker.join()
    if errors:
        raise errors[0]
    return 0
