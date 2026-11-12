"""The public ``Pattern`` / ``Match`` types and the :func:`compile` entry point."""

from __future__ import annotations

from .analysis import first_chars, is_start_anchored
from .compiler import UNSET, Program
from .parser import parse


class Match:
    """The first match of a pattern in a subject.

    Attributes:
        start: offset of the first matched character.
        end: exclusive end offset of the match.
        spans: one entry per group, in order: ``(start, end)`` or ``None``
            when the group did not take part in the match.
    """

    __slots__ = ("start", "end", "spans")

    def __init__(self, start: int, end: int, spans: tuple[tuple[int, int] | None, ...]) -> None:
        self.start = start
        self.end = end
        self.spans = spans

    def span(self, group: int = 0) -> tuple[int, int] | None:
        """Span of ``group`` (0 is the whole match), or ``None`` if unset."""
        if group == 0:
            return (self.start, self.end)
        return self.spans[group - 1]

    def __repr__(self) -> str:
        return f"Match(start={self.start}, end={self.end}, spans={self.spans!r})"

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Match):
            return NotImplemented
        return (self.start, self.end, self.spans) == (other.start, other.end, other.spans)

    def __hash__(self) -> int:
        return hash((self.start, self.end, self.spans))


class Pattern:
    """A compiled regular expression.  Create one with :func:`compile`.

    A ``Pattern`` keeps its match state internally, so one instance must not
    be used from several threads at once.
    """

    def __init__(self, pattern: str) -> None:
        tree, groups = parse(pattern)
        self.pattern = pattern
        #: Number of capturing groups.
        self.groups = groups
        self._program = Program(tree, groups)
        chars, nullable = first_chars(tree)
        self._anchored = is_start_anchored(tree)
        # Characters a match can begin with; None means "try every start".
        self._first: frozenset[str] | None = None if nullable else chars

    def search(self, subject: str) -> Match | None:
        """Find the leftmost match (Perl-style, greedy, ordered choice)."""
        program = self.program
        entry = program.entry
        n = len(subject)
        if self._anchored:
            starts = range(1)
        elif self._first is None:
            starts = range(n + 1)
        else:
            first = self._first
            starts = [i for i, c in enumerate(subject) if c in first]
        for start in starts:
            if entry(subject, start):
                return self._result(start)
        return None

    @property
    def program(self) -> Program:
        return self._program

    def _result(self, start: int) -> Match:
        program = self._program
        caps = program.caps
        spans = tuple(
            None if caps[k] == UNSET else (caps[k], caps[k + 1])
            for k in range(0, len(caps), 2)
        )
        end = program.end[0]
        program.reset()
        return Match(start, end, spans)

    def __repr__(self) -> str:
        return f"Pattern({self.pattern!r})"


def compile(pattern: str) -> Pattern:  # noqa: A001 - mirrors re.compile
    """Compile ``pattern``; raises :class:`~btregex.errors.PatternSyntaxError`."""
    return Pattern(pattern)
