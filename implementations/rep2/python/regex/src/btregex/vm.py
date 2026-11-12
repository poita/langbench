"""Backtracking virtual machine executing programs from :mod:`btregex.compiler`.

The machine keeps an explicit stack of choice points, so recursion depth is
never a concern. Each choice point is ``(pc, pos, trail_len, lowest_pos)``:
resuming it continues at ``pc`` with position ``pos`` after undoing register
writes back to ``trail_len``. When ``pos > lowest_pos`` the entry is pushed
back with ``pos - 1`` -- this is how a greedy ``REP`` run gives characters back
one at a time using a single stack entry. Ordinary choice points use
``lowest_pos == pos``.

Register writes (group boundaries and loop marks) are recorded on a trail, so
undoing a failed path costs time proportional to the writes it made.
"""

from __future__ import annotations

from .compiler import (ANY, BOL, EOL, JMP, LOOPEND, MATCH, REP, SAVE, SET,
                       SPLIT, STR)


def run(prog: tuple, s: str, start: int, regs: list[int]) -> int:
    """Try to match ``prog`` against ``s`` beginning exactly at ``start``.

    Returns the end of the match, or ``-1``. On success ``regs`` holds the
    captures of the successful path; on failure ``regs`` is left as it was.
    """
    n = len(s)
    stack: list[tuple[int, int, int, int]] = []
    trail: list[tuple[int, int]] = []
    pc = 0
    pos = start
    while True:
        op, a, b, c = prog[pc]
        if op == STR:
            if s.startswith(a, pos):
                pos += b
                pc += 1
                continue
        elif op == REP:
            if a is None:
                end = pos + c
                if end > n:
                    end = n
            else:
                lim = pos + c
                if lim > n:
                    lim = n
                end = pos
                while end < lim and s[end] in a:
                    end += 1
            low = pos + b
            if end >= low:
                if end > low:
                    stack.append((pc + 1, end - 1, len(trail), low))
                pos = end
                pc += 1
                continue
        elif op == SPLIT:
            stack.append((a, pos, len(trail), pos))
            pc += 1
            continue
        elif op == SAVE:
            trail.append((a, regs[a]))
            regs[a] = pos
            pc += 1
            continue
        elif op == SET:
            if pos < n and s[pos] in a:
                pos += 1
                pc += 1
                continue
        elif op == JMP:
            pc = a
            continue
        elif op == LOOPEND:
            pc = c if pos == regs[a] else b
            continue
        elif op == ANY:
            if pos < n:
                pos += 1
                pc += 1
                continue
        elif op == BOL:
            if pos == 0:
                pc += 1
                continue
        elif op == EOL:
            if pos == n:
                pc += 1
                continue
        elif op == MATCH:
            return pos
        # Failure: backtrack to the most recent choice point.
        if not stack:
            while trail:
                r, old = trail.pop()
                regs[r] = old
            return -1
        pc, pos, tl, low = stack.pop()
        if pos > low:
            stack.append((pc, pos - 1, tl, low))
        while len(trail) > tl:
            r, old = trail.pop()
            regs[r] = old
