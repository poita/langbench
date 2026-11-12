"""The public library API: compile and run Vellum module streams."""

from __future__ import annotations

import sys
import threading
from dataclasses import dataclass

from .checker import Checker
from .compiler import Compiler, Image
from .diagnostics import CompileError, Panic
from .items import build_program
from .lexer import tokenize
from .parser import parse_module
from .source import split_modules
from .vm import VM


_STACK_SIZES = (512 * 1024 * 1024, 128 * 1024 * 1024, 32 * 1024 * 1024)


def compile_program(source: str) -> Image:
    """Compile a module stream to a bytecode :class:`Image`.

    Raises :class:`CompileError` with the diagnostic if the program is rejected."""
    modules = split_modules(source)
    token_lists = [tokenize(m.text) for m in modules]
    parsed = [
        (m.name, m, parse_module(toks, m.end_position()))
        for m, toks in zip(modules, token_lists)
    ]
    program, resolver = build_program(parsed)
    checker = Checker(program, resolver)
    checker.run()
    return Compiler(program).compile(checker.compile_order)


@dataclass(slots=True)
class RunResult:
    """What a run produced: ``output`` is the exact stdout text."""

    output: str
    panic: str | None = None
    error: CompileError | None = None


def run_source(source: str) -> RunResult:
    """Compile and run ``source``; never raises for Vellum-level failures.

    The work happens on a worker thread with a large stack and a raised
    recursion limit, because the front end and the structural-equality helpers
    recurse over deeply nested programs and values."""
    box: list[RunResult] = []
    old_limit = sys.getrecursionlimit()
    old_stack = threading.stack_size()
    sys.setrecursionlimit(1_000_000)
    try:
        for size in _STACK_SIZES:
            try:
                threading.stack_size(size)
                worker = threading.Thread(target=lambda: box.append(_run_source(source)))
                worker.start()
            except (ValueError, RuntimeError, MemoryError):
                continue  # this stack size is not available; try a smaller one
            worker.join()
            break
        else:
            box.append(_run_source(source))
    finally:
        threading.stack_size(old_stack)
        sys.setrecursionlimit(old_limit)
    return box[0]


def _run_source(source: str) -> RunResult:
    try:
        image = compile_program(source)
    except CompileError as e:
        return RunResult(e.render() + "\n", error=e)
    out: list[str] = []
    vm = VM(image, out)
    try:
        vm.run()
    except Panic as p:
        out.append("panic: " + p.message + "\n")
        return RunResult("".join(out), panic=p.message)
    return RunResult("".join(out))
