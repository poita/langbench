"""Public API: compile a pattern, search subjects, inspect matches."""

from __future__ import annotations

from dataclasses import dataclass

from .analysis import anchored_start, first_set
from .compiler import compile_tree
from .parser import parse
from .vm import run


@dataclass(frozen=True, slots=True)
class Match:
    """The first match of a pattern in a subject.

    ``start``/``end`` delimit the whole match (``end`` exclusive). ``groups``
    holds one entry per capture group, in order of their opening parenthesis:
    a ``(start, end)`` pair, or ``None`` for a group that did not take part in
    the match.
    """

    string: str
    start: int
    end: int
    groups: tuple[tuple[int, int] | None, ...]

    def span(self, group: int = 0) -> tuple[int, int] | None:
        """Span of ``group`` (0 is the whole match); ``None`` if unset."""
        if group == 0:
            return (self.start, self.end)
        if not 1 <= group <= len(self.groups):
            raise IndexError(f"no such group: {group}")
        return self.groups[group - 1]

    def group(self, group: int = 0) -> str | None:
        """Text matched by ``group`` (0 is the whole match); ``None`` if unset."""
        sp = self.span(group)
        return None if sp is None else self.string[sp[0]:sp[1]]


class Pattern:
    """A compiled pattern. Build one with :func:`compile`."""

    def __init__(self, pattern: str) -> None:
        tree, groups = parse(pattern)
        self.pattern = pattern
        self.group_count = groups
        self._program, self._nregs = compile_tree(tree, groups)
        first, nullable = first_set(tree)
        # Start positions are skipped when no match can begin there.
        self._first = None if nullable else first
        self._anchored = anchored_start(tree)

    def __repr__(self) -> str:
        return f"btregex.compile({self.pattern!r})"

    def search(self, subject: str) -> Match | None:
        """Return the first match in ``subject``, or ``None``.

        Start positions are tried left to right; at each one the pattern is
        matched with greedy, ordered-choice backtracking.
        """
        n = len(subject)
        first = self._first
        prog = self._program
        regs = [-1] * self._nregs
        last = 0 if self._anchored else n
        for start in range(last + 1):
            if first is not None and (start >= n or subject[start] not in first):
                continue
            end = run(prog, subject, start, regs)
            if end >= 0:
                groups = []
                for g in range(1, self.group_count + 1):
                    ge = regs[2 * g + 1]
                    groups.append(None if ge < 0 else (regs[2 * g], ge))
                return Match(subject, start, end, tuple(groups))
        return None


def compile(pattern: str) -> Pattern:
    """Compile ``pattern``; raises :class:`~btregex.errors.PatternSyntaxError`."""
    return Pattern(pattern)


def search(pattern: str, subject: str) -> Match | None:
    """Convenience wrapper: ``compile(pattern).search(subject)``."""
    return compile(pattern).search(subject)
