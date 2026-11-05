#!/usr/bin/env python3
"""langvm: compile and run a Vellum module stream read from stdin."""

import sys
import threading

from verrors import CompileError, Panic
from lexer import lex
from vparser import parse
from items import split_modules, build_program, run_item_passes
from check import check_program
from compile import compile_program
from vm import VM


def run_source(text):
    """Return everything the tool writes to stdout for this input."""
    try:
        mods = split_modules(text)
        prog = build_program(mods)
        for m in prog.modules:
            m.src = '\n'.join(m.lines)
            m.toks = lex(m.src)
        for m in prog.modules:
            m.items = parse(m.toks)
        run_item_passes(prog)
        checker = check_program(prog)
        cprog = compile_program(prog, checker)
    except CompileError as e:
        return e.text() + '\n'
    machine = VM(cprog)
    try:
        machine.run()
    except Panic as p:
        return ''.join(machine.out) + 'panic: ' + p.msg + '\n'
    return ''.join(machine.out)


def main():
    data = sys.stdin.buffer.read()
    text = data.decode('utf-8')
    out = run_source(text)
    sys.stdout.write(out)
    sys.stdout.flush()


def entry():
    # A large host stack and recursion limit: nothing here recurses per Vellum
    # call, but deeply nested higher-order built-ins and deeply nested
    # expressions do recurse in the compiler and the checker.
    sys.setrecursionlimit(200000)
    threading.stack_size(64 * 1024 * 1024)
    box = []

    def go():
        try:
            main()
        except BaseException as exc:  # re-raised on the main thread
            box.append(exc)

    t = threading.Thread(target=go)
    t.start()
    t.join()
    if box:
        raise box[0]


if __name__ == '__main__':
    entry()
