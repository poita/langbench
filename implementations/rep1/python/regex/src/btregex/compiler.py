"""Compile a syntax tree into a graph of Python closures.

Every node is compiled together with the function that continues matching
after it (its *static continuation*), so matching allocates no continuation
objects at run time.  A compiled matcher has the signature ``f(s, i) -> bool``;
it returns ``True`` as soon as the whole pattern has matched, leaving the
capture table filled in.  The semantics follow SPEC section 3 exactly:
alternatives and loop iterations are explored depth-first, and any capture
write on a path that fails is undone by the code that made it, so the cost of
undoing is proportional to the number of writes.

Counted quantifiers are expanded: ``x{2,4}`` becomes two required copies of
``x`` followed by two nested optional copies.  Unbounded loops are real
cycles.  Quantified single-character atoms (``a*``, ``[0-9]+``, ``.{2,5}``)
take a fast path that scans forward and gives characters back one at a time,
which is equivalent to the general rule and avoids deep recursion.
"""

from __future__ import annotations

from collections.abc import Callable

from .nodes import (
    AnyChar,
    Alternation,
    CharClass,
    EndAnchor,
    Group,
    Literal,
    Node,
    Repeat,
    Sequence,
    StartAnchor,
)

Matcher = Callable[[str, int], bool]

UNSET = -1


class Program:
    """A compiled pattern: an entry matcher plus the mutable match state."""

    __slots__ = ("entry", "caps", "end", "groups")

    def __init__(self, tree: Node, groups: int) -> None:
        self.groups = groups
        #: caps[2g-2], caps[2g-1] hold the start/end of group g, or UNSET.
        self.caps: list[int] = [UNSET] * (2 * groups)
        #: end[0] receives the end offset of the overall match.
        self.end: list[int] = [0]
        compiler = _Compiler(self.caps)
        end = self.end

        def accept(s: str, j: int) -> bool:
            end[0] = j
            return True

        self.entry: Matcher = compiler.compile(tree, accept)

    def reset(self) -> None:
        """Mark every group unset (needed only after a successful match)."""
        caps = self.caps
        for k in range(len(caps)):
            caps[k] = UNSET


class _Compiler:
    def __init__(self, caps: list[int]) -> None:
        self.caps = caps
        #: Scratch: tmp_start[g] is the start of the group-g iteration in progress.
        self.group_start: dict[int, list[int]] = {}

    def compile(self, node: Node, nxt: Matcher) -> Matcher:
        if isinstance(node, Literal):
            return self._literal(node.char, nxt)
        if isinstance(node, AnyChar):
            return self._any(nxt)
        if isinstance(node, CharClass):
            return self._class(node.chars, nxt)
        if isinstance(node, StartAnchor):
            return lambda s, i: i == 0 and nxt(s, i)
        if isinstance(node, EndAnchor):
            return lambda s, i: i == len(s) and nxt(s, i)
        if isinstance(node, Sequence):
            return self._sequence(node.items, nxt)
        if isinstance(node, Alternation):
            return self._alternation(node.branches, nxt)
        if isinstance(node, Group):
            return self._group(node, nxt)
        if isinstance(node, Repeat):
            return self._repeat(node, nxt)
        raise TypeError(f"unknown node {node!r}")

    # -- leaves ------------------------------------------------------------

    @staticmethod
    def _literal(text: str, nxt: Matcher) -> Matcher:
        n = len(text)
        if n == 1:
            return lambda s, i: s.startswith(text, i) and nxt(s, i + 1)
        return lambda s, i: s.startswith(text, i) and nxt(s, i + n)

    @staticmethod
    def _any(nxt: Matcher) -> Matcher:
        return lambda s, i: i < len(s) and nxt(s, i + 1)

    @staticmethod
    def _class(chars: frozenset[str], nxt: Matcher) -> Matcher:
        return lambda s, i: s[i : i + 1] in chars and nxt(s, i + 1)

    # -- combinators -------------------------------------------------------

    def _sequence(self, items: tuple[Node, ...], nxt: Matcher) -> Matcher:
        # Merge runs of literals into one string comparison.
        merged: list[Node | str] = []
        for item in items:
            if isinstance(item, Literal):
                if merged and isinstance(merged[-1], str):
                    merged[-1] += item.char
                else:
                    merged.append(item.char)
            else:
                merged.append(item)
        cont = nxt
        for item in reversed(merged):
            if isinstance(item, str):
                cont = self._literal(item, cont)
            else:
                cont = self.compile(item, cont)
        return cont

    def _alternation(self, branches: tuple[Node, ...], nxt: Matcher) -> Matcher:
        compiled = tuple(self.compile(b, nxt) for b in branches)
        if len(compiled) == 2:
            first, second = compiled
            return lambda s, i: first(s, i) or second(s, i)

        def alt(s: str, i: int) -> bool:
            for branch in compiled:
                if branch(s, i):
                    return True
            return False

        return alt

    def _group(self, node: Group, nxt: Matcher) -> Matcher:
        caps = self.caps
        a = 2 * node.index - 2
        b = a + 1
        start = [UNSET]  # start offset of the iteration currently inside the group

        def close(s: str, j: int) -> bool:
            old_a = caps[a]
            old_b = caps[b]
            caps[a] = start[0]
            caps[b] = j
            if nxt(s, j):
                return True
            caps[a] = old_a
            caps[b] = old_b
            return False

        body = self.compile(node.body, close)

        def open_(s: str, i: int) -> bool:
            old = start[0]
            start[0] = i
            if body(s, i):
                return True
            start[0] = old
            return False

        return open_

    # -- repetition --------------------------------------------------------

    def _repeat(self, node: Repeat, nxt: Matcher) -> Matcher:
        lo, hi, body = node.min, node.max, node.body
        if hi == 0:
            return nxt  # x{0}: the atom never runs
        if isinstance(body, (Literal, AnyChar, CharClass)):
            return self._simple_repeat(body, lo, hi, nxt)
        if hi is None:
            tail = self._optional(body, nxt, None)
        else:
            tail = nxt
            for k in range(hi - lo):
                tail = self._optional(body, nxt, tail if k else None, last=(k == 0))
        cont = tail
        for _ in range(lo):
            cont = self.compile(body, cont)
        return cont

    def _optional(
        self, body: Node, nxt: Matcher, again: Matcher | None, last: bool = False
    ) -> Matcher:
        """One optional iteration of ``body``.

        After an iteration ending at ``j`` the loop continues with ``again``
        (or with itself when ``again`` is ``None``) unless the iteration was
        empty, in which case it continues with ``nxt``.  If the iteration
        fails, ``nxt`` is tried without it.  ``last`` marks the final copy of
        a bounded repetition, where both routes lead to ``nxt``.
        """
        if last:
            inner = self.compile(body, nxt)
            return lambda s, i: inner(s, i) or nxt(s, i)

        slot = [0]  # start offset of the iteration in progress
        target: list[Matcher] = []

        def after(s: str, j: int) -> bool:
            if j == slot[0]:
                return nxt(s, j)
            return target[0](s, j)

        inner = self.compile(body, after)

        def opt(s: str, i: int) -> bool:
            old = slot[0]
            slot[0] = i
            if inner(s, i):
                return True
            slot[0] = old
            return nxt(s, i)

        target.append(opt if again is None else again)
        return opt

    @staticmethod
    def _simple_repeat(body: Node, lo: int, hi: int | None, nxt: Matcher) -> Matcher:
        """Greedy loop over a single-character atom, without recursion."""
        if isinstance(body, AnyChar):
            def scan(s: str, i: int, limit: int) -> int:
                return limit
        elif isinstance(body, Literal):
            ch = body.char

            def scan(s: str, i: int, limit: int) -> int:
                j = i
                while j < limit and s[j] == ch:
                    j += 1
                return j
        else:
            chars = body.chars  # type: ignore[attr-defined]

            def scan(s: str, i: int, limit: int) -> int:
                j = i
                while j < limit and s[j] in chars:
                    j += 1
                return j

        def loop(s: str, i: int) -> bool:
            limit = len(s)
            if hi is not None and i + hi < limit:
                limit = i + hi
            j = scan(s, i, limit)
            low = i + lo
            while j >= low:
                if nxt(s, j):
                    return True
                j -= 1
            return False

        return loop
