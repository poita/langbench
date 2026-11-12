"""The batch input/output format used by the command-line tool.

Input::

    N
    pattern_1
    M_1
    subject_1_1
    ...

Output: one line per subject, ``no`` or ``match <start> <end>|<gs>,<ge>|-...``.
"""

from __future__ import annotations

from collections.abc import Iterator

from .pattern import Match, compile


def parse_input(text: str) -> Iterator[tuple[str, list[str]]]:
    """Yield ``(pattern, subjects)`` for each pattern in the input text.

    Lines are strictly positional and taken verbatim.
    """
    lines = text.split("\n")
    count = int(lines[0])
    pos = 1
    for _ in range(count):
        pattern = lines[pos]
        m = int(lines[pos + 1])
        pos += 2
        yield pattern, lines[pos : pos + m]
        pos += m


def format_match(match: Match | None) -> str:
    """Render a search result as one output line (without the newline)."""
    if match is None:
        return "no"
    parts = [f"match {match.start} {match.end}"]
    for span in match.spans:
        parts.append("-" if span is None else f"{span[0]},{span[1]}")
    return "|".join(parts)


def run(text: str) -> Iterator[str]:
    """Process a whole input document, yielding one output chunk per pattern.

    Each chunk is a newline-terminated block of result lines (possibly empty).
    """
    for pattern, subjects in parse_input(text):
        if not subjects:
            yield ""
            continue
        compiled = compile(pattern)
        search = compiled.search
        yield "".join([format_match(search(s)) + "\n" for s in subjects])
