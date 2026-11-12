"""Splitting the stdin text into modules (SPEC section 2)."""

from __future__ import annotations

import re
from dataclasses import dataclass

from .diagnostics import CompileError

KEYWORDS = frozenset(
    "as break continue else enum false fn for if impl in let match pub return "
    "self struct trait true use var when while".split()
)

_HEADER = re.compile(r"@module ([A-Za-z_][A-Za-z0-9_]*)\Z")


@dataclass(slots=True)
class SourceModule:
    """One module of the stream: its name and its body lines."""

    name: str
    lines: list[str]

    @property
    def text(self) -> str:
        return "\n".join(self.lines)

    def end_position(self) -> tuple[int, int]:
        """Position one past the end of the module (for early-EOF diagnostics)."""
        if not self.lines:
            return (1, 1)
        return (len(self.lines), len(self.lines[-1]) + 1)


def split_lines(text: str) -> list[str]:
    """Split on LF; a CR just before an LF is dropped; no phantom final line."""
    if text == "":
        return []
    lines = text.split("\n")
    terminated = lines[-1] == ""
    if terminated:
        lines.pop()
    last = len(lines) - 1
    return [
        ln[:-1] if ln.endswith("\r") and (i < last or terminated) else ln
        for i, ln in enumerate(lines)
    ]


def _header_name(line: str) -> str | None:
    m = _HEADER.match(line)
    if not m:
        return None
    name = m.group(1)
    if name == "_" or name in KEYWORDS or len(name) > 200:
        return None
    return name


def split_modules(text: str) -> list[SourceModule]:
    """Split the module stream; raises :class:`CompileError` for pass 0 errors."""
    lines = split_lines(text)
    if not lines or _header_name(lines[0]) is None:
        raise CompileError("bad-module", 1, 1)
    modules: list[SourceModule] = []
    headers: list[tuple[str, int]] = []
    for lineno, line in enumerate(lines, 1):
        if line.startswith("@"):
            name = _header_name(line)
            if name is None:
                raise CompileError("bad-module", lineno, 1)
            headers.append((name, lineno))
            modules.append(SourceModule(name, []))
        else:
            modules[-1].lines.append(line)
    seen: set[str] = set()
    for name, lineno in headers:
        if name in seen:
            raise CompileError("dup-module", lineno, 1)
        seen.add(name)
    return modules
