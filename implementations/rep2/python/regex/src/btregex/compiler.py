"""Compile a syntax tree into a flat program for :mod:`btregex.vm`.

A program is a list of ``(op, a, b, c)`` tuples. Instruction semantics (``pos``
is the subject position, ``pc`` the program counter):

``CHAR``/``STR``  match literal text ``a`` (length ``b``)
``ANY``           consume any one character
``SET``           consume one character in the frozenset ``a``
``BOL``/``EOL``   zero-width anchors
``SPLIT a``       continue at ``pc+1``; on failure resume at ``a`` (same ``pos``)
``JMP a``         goto ``a``
``SAVE a``        write ``pos`` into register ``a`` (undone on backtracking)
``LOOPEND a b c`` end of an optional loop iteration: if ``pos == regs[a]`` the
                  iteration was empty and the loop ends (goto ``c``);
                  otherwise goto ``b`` to try another iteration
``REP a b c``     greedy run of between ``b`` and ``c`` characters from the set
                  ``a`` (``a is None`` means any character), giving characters
                  back one at a time on backtracking
``MATCH``         success

Counted quantifiers are expanded: ``x{n,m}`` becomes ``n`` copies of ``x``
followed by ``m-n`` nested optional iterations (or a star loop when unbounded).
Registers ``2g`` / ``2g+1`` hold the start / end of group ``g``; registers
above ``2*groups + 1`` are loop marks.
"""

from __future__ import annotations

import sys

from .ast import (Alt, Any, Bol, Char, CharSet, Eol, Group, Node,
                  Repeat, Seq)

(STR, ANY, SET, BOL, EOL, SPLIT, JMP, SAVE, LOOPEND, REP, MATCH) = range(11)

#: Effectively "no upper bound" for REP.
UNBOUNDED = 1 << 60

Instr = tuple  # (op, a, b, c)


class Compiler:
    def __init__(self, group_count: int) -> None:
        self.code: list[list] = []
        self.nregs = 2 * group_count + 2

    def emit(self, op: int, a=None, b=None, c=None) -> int:
        self.code.append([op, a, b, c])
        return len(self.code) - 1

    def new_mark(self) -> int:
        self.nregs += 1
        return self.nregs - 1

    def compile(self, node: Node) -> None:
        if isinstance(node, Char):
            self.emit(STR, node.char, 1)
        elif isinstance(node, Any):
            self.emit(ANY)
        elif isinstance(node, CharSet):
            self.emit(SET, node.chars)
        elif isinstance(node, Bol):
            self.emit(BOL)
        elif isinstance(node, Eol):
            self.emit(EOL)
        elif isinstance(node, Seq):
            self._seq(node.items)
        elif isinstance(node, Alt):
            self._alt(node.branches)
        elif isinstance(node, Group):
            self.emit(SAVE, 2 * node.index)
            self.compile(node.child)
            self.emit(SAVE, 2 * node.index + 1)
        elif isinstance(node, Repeat):
            self._repeat(node)
        else:  # pragma: no cover
            raise TypeError(node)

    def _seq(self, items: list[Node]) -> None:
        run: list[str] = []

        def flush() -> None:
            if run:
                text = "".join(run)
                self.emit(STR, text, len(text))
                run.clear()

        for item in items:
            if isinstance(item, Char):
                run.append(item.char)
            else:
                flush()
                self.compile(item)
        flush()

    def _alt(self, branches: list[Node]) -> None:
        jumps = []
        for branch in branches[:-1]:
            split = self.emit(SPLIT)
            self.compile(branch)
            jumps.append(self.emit(JMP))
            self.code[split][1] = len(self.code)
        self.compile(branches[-1])
        for j in jumps:
            self.code[j][1] = len(self.code)

    def _repeat(self, node: Repeat) -> None:
        child, lo, hi = node.child, node.min, node.max
        if isinstance(child, (Char, Any, CharSet)):
            if hi == 0:
                return
            if isinstance(child, Any):
                chars = None
            elif isinstance(child, Char):
                chars = frozenset(child.char)
            else:
                chars = child.chars
            self.emit(REP, chars, lo, UNBOUNDED if hi is None else hi)
            return
        if hi == 0:
            return  # the atom never runs; its groups stay unset
        for _ in range(lo):
            self.compile(child)
        if hi is None:
            self._optional_iteration(child, loop=True, ends=[])
            return
        ends: list[int] = []
        for _ in range(hi - lo):
            self._optional_iteration(child, loop=False, ends=ends)
        for e in ends:
            self.code[e][1 if self.code[e][0] == SPLIT else 3] = len(self.code)

    def _optional_iteration(self, child: Node, loop: bool, ends: list[int]) -> None:
        """Emit ``(child | <stop>)`` where an empty child iteration also stops.

        With ``loop`` the iteration jumps back to its own start afterwards.
        Otherwise it falls through to the next iteration; instructions that
        must jump to the end of the whole repetition are appended to ``ends``.
        """
        start = len(self.code)
        split = self.emit(SPLIT)
        mark = None
        if child.min_len == 0:
            mark = self.new_mark()
            self.emit(SAVE, mark)
        self.compile(child)
        if mark is not None:
            end_instr = self.emit(LOOPEND, mark, start if loop else len(self.code) + 1)
            if loop:
                self.code[split][1] = len(self.code)
                self.code[end_instr][3] = len(self.code)
            else:
                ends.append(split)
                ends.append(end_instr)
        elif loop:
            self.emit(JMP, start)
            self.code[split][1] = len(self.code)
        else:
            ends.append(split)


def compile_tree(tree: Node, group_count: int) -> tuple[tuple[Instr, ...], int]:
    """Compile ``tree``; return ``(program, number_of_registers)``."""
    limit = sys.getrecursionlimit()
    sys.setrecursionlimit(max(limit, 20000))
    try:
        c = Compiler(group_count)
        c.compile(tree)
        c.emit(MATCH)
    finally:
        sys.setrecursionlimit(limit)
    return tuple(tuple(i) for i in c.code), c.nregs
