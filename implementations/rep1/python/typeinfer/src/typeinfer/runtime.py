"""Helpers for running deeply recursive work.

Parsing, inference and printing recurse on the nesting depth of the program and
of the types (thousands of levels).  CPython's pure-Python calls do not use the
C stack, but the interpreter's recursion limit must be raised, and running in a
thread with a big stack is a cheap safeguard.
"""

from __future__ import annotations

import sys
import threading
from collections.abc import Callable
from typing import TypeVar

T = TypeVar("T")

RECURSION_LIMIT = 1_000_000
_STACK_SIZES = (512 << 20, 128 << 20, 32 << 20)


def run_deep(func: Callable[[], T]) -> T:
    """Call ``func()`` with a high recursion limit on a large-stack thread."""
    sys.setrecursionlimit(RECURSION_LIMIT)
    outcome: list[tuple[bool, object]] = []

    def target() -> None:
        try:
            outcome.append((True, func()))
        except BaseException as exc:  # re-raised in the caller
            outcome.append((False, exc))

    thread = None
    for size in _STACK_SIZES:
        try:
            threading.stack_size(size)
            thread = threading.Thread(target=target)
            thread.start()
            break
        except (ValueError, RuntimeError):
            thread = None
    if thread is None:
        target()
    else:
        thread.join()
    ok, value = outcome[0]
    if not ok:
        raise value  # type: ignore[misc]
    return value  # type: ignore[return-value]
