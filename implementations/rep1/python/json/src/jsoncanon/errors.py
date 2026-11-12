"""Exception types raised by :mod:`jsoncanon`."""

from __future__ import annotations


class JSONError(ValueError):
    """The input is not a valid JSON document.

    ``pos`` is the offset (in characters of the decoded text, or in bytes for
    UTF-8 errors) at which the problem was detected, when known.
    """

    def __init__(self, message: str, pos: int | None = None) -> None:
        super().__init__(message if pos is None else f"{message} at offset {pos}")
        self.msg = message
        self.pos = pos
