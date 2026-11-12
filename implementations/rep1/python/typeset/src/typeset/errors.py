"""Error type for invalid Codexa input."""

from __future__ import annotations


class CodexaError(Exception):
    """The first problem found in the settings or the document.

    ``file`` is ``settings.cfg``, ``document.cdx`` or ``-``; ``line`` and
    ``col`` are 1-based (``col`` counts Unicode scalar values).  ``code`` is
    one of the error codes of the specification, e.g. ``bad-length``.
    """

    def __init__(self, file: str, line: int, col: int, code: str) -> None:
        super().__init__(f"{file}:{line}:{col}: {code}")
        self.file = file
        self.line = line
        self.col = col
        self.code = code

    def format(self) -> str:
        """Return the one-line ``file:line:col: code`` form (no newline)."""
        return f"{self.file}:{self.line}:{self.col}: {self.code}"
