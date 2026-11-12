"""Error types shared by every part of Kiln.

A build fails with exactly one :class:`KilnError`.  Its *kind* is one of the
``E_*`` names from the specification and its *detail* is the (byte string)
text that follows the kind in the log.

Lexing and parsing code raises the location-less :class:`SyntaxFault`; the
code that knows which logical line was being processed converts it into an
``E_PARSE`` :class:`KilnError`.
"""

from __future__ import annotations

__all__ = ["KilnError", "SyntaxFault", "NO_DETAIL_KINDS", "type_error"]

#: Error kinds that are rendered without a detail.
NO_DETAIL_KINDS = frozenset({"E_NO_DEFAULT", "E_DIV_ZERO"})


class KilnError(Exception):
    """A build error: a kind (``"E_TYPE"``) and a byte-string detail."""

    def __init__(self, kind: str, detail: bytes | str = b"") -> None:
        if isinstance(detail, str):
            detail = detail.encode("utf-8")
        super().__init__(kind, detail)
        self.kind = kind
        self.detail = detail

    def render(self) -> bytes:
        """The error as it appears after ``  error `` in ``log.txt``."""
        kind = self.kind.encode("ascii")
        if self.kind in NO_DETAIL_KINDS:
            return kind
        return kind + b" " + self.detail

    def __str__(self) -> str:
        return self.render().decode("utf-8", "replace")


class SyntaxFault(Exception):
    """A lexical or grammatical violation whose location is not yet known."""


def type_error(site: str | bytes, expected: str, actual: str) -> KilnError:
    """Build an ``E_TYPE`` error: ``<site>: expected <expected>, got <actual>``."""
    if isinstance(site, str):
        site = site.encode("utf-8")
    return KilnError("E_TYPE", b"%b: expected %b, got %b" % (site, expected.encode(), actual.encode()))
