"""Command-line interface.

Reads the whole of stdin (a JSON context, a ``--`` line and named templates),
renders the first template and prints the result, or ``error: <kind>`` if the
engine reports an error.  The exit status is 0 in both cases.
"""

from __future__ import annotations

import sys
import threading
from typing import IO

from .environment import Environment
from .errors import TemplateError
from .inputformat import parse_document


def run(data: str) -> str:
    """Process one input document and return the text to print (no newline)."""
    document = parse_document(data)
    try:
        return Environment(document.templates).render(document.main, document.context)
    except TemplateError as exc:
        return f"error: {exc.kind}"


def main(argv: list[str] | None = None, stdin: IO[bytes] | None = None, stdout: IO[bytes] | None = None) -> int:
    """Entry point; returns the process exit status."""
    stdin = stdin or sys.stdin.buffer
    stdout = stdout or sys.stdout.buffer
    data = stdin.read().decode("utf-8")
    result = run(data)
    stdout.write(result.encode("utf-8") + b"\n")
    stdout.flush()
    return 0


def main_with_big_stack(argv: list[str] | None = None) -> int:
    """Run :func:`main` in a thread with a large stack and recursion limit.

    The interpreter is recursive (nested macros, expressions and blocks), so
    deep templates need more room than the defaults allow.
    """
    sys.setrecursionlimit(1_000_000)
    sys.set_int_max_str_digits(0)
    threading.stack_size(512 * 1024 * 1024)
    result: list[int] = []
    errors: list[BaseException] = []

    def target() -> None:
        try:
            result.append(main(argv))
        except BaseException as exc:  # re-raised in the main thread
            errors.append(exc)

    thread = threading.Thread(target=target)
    thread.start()
    thread.join()
    if errors:
        raise errors[0]
    return result[0]
