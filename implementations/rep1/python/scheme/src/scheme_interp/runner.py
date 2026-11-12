"""Running programs with enough host stack for deep non-tail recursion."""

from __future__ import annotations

import sys
import threading
from typing import Callable, TypeVar

from .interpreter import Interpreter

T = TypeVar("T")

_STACK_BYTES = 512 * 1024 * 1024
_RECURSION_LIMIT = 1_000_000


def call_with_deep_stack(fn: Callable[[], T]) -> T:
    """Call ``fn()`` in a thread with a large stack and recursion limit.

    Non-tail Scheme recursion nests Python frames, so deeply recursive
    programs need more than the default stack.  The result (or exception) of
    ``fn`` is passed back to the caller.
    """
    result: list = []
    failure: list = []

    def target() -> None:
        try:
            result.append(fn())
        except BaseException as e:  # re-raised in the calling thread
            failure.append(e)

    old_limit = sys.getrecursionlimit()
    old_stack = threading.stack_size()
    sys.setrecursionlimit(_RECURSION_LIMIT)
    threading.stack_size(_STACK_BYTES)
    try:
        thread = threading.Thread(target=target)
        thread.start()
        thread.join()
    finally:
        threading.stack_size(old_stack)
        sys.setrecursionlimit(old_limit)
    if failure:
        raise failure[0]
    return result[0]


def run_program(source: str) -> str:
    """Run ``source`` in a fresh interpreter and return its output text."""
    return call_with_deep_stack(lambda: Interpreter().run(source))
