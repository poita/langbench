"""Error types shared by every stage of a build.

A build fails with exactly one :class:`KilnError`.  Its ``kind`` is one of the
``E_*`` identifiers and ``detail`` is the (already formatted) text that follows
it in the log.  Both are byte strings because KBL strings are byte strings and
may be echoed verbatim into the log.
"""

from __future__ import annotations


def _b(value: bytes | str | int) -> bytes:
    if isinstance(value, bytes):
        return value
    if isinstance(value, int):
        return str(value).encode()
    return value.encode("utf-8")


class KilnError(Exception):
    """A build error: ``E_<KIND>`` plus an optional detail string."""

    def __init__(self, kind: str, detail: bytes | str = b"") -> None:
        self.kind = kind
        self.detail = _b(detail)
        super().__init__(self.render().decode("utf-8", "replace"))

    def render(self) -> bytes:
        """The text after ``error `` on the log's error line."""
        if self.detail:
            return self.kind.encode() + b" " + self.detail
        return self.kind.encode()

    def __eq__(self, other: object) -> bool:
        return (
            isinstance(other, KilnError)
            and self.kind == other.kind
            and self.detail == other.detail
        )

    def __hash__(self) -> int:
        return hash((self.kind, self.detail))


class SyntaxFail(Exception):
    """Internal: a lexical or grammar violation, before a line is attached.

    The parser converts it into ``E_PARSE <file>:<line>``.
    """


def parse_error(path: bytes, line: int) -> KilnError:
    return KilnError("E_PARSE", path + b":" + str(line).encode())


def type_error(site: str | bytes, expected: str, actual: str) -> KilnError:
    return KilnError(
        "E_TYPE", _b(site) + b": expected " + expected.encode() + b", got " + actual.encode()
    )


def arity_error(kind: str, name: str | bytes, expected: str, got: int) -> KilnError:
    return KilnError(
        "E_ARITY",
        _b(kind) + b" " + _b(name) + b": expected " + expected.encode() + b", got " + _b(got),
    )


def arg_error(kind: str, name: str | bytes, reason: str | bytes) -> KilnError:
    return KilnError("E_ARG", _b(kind) + b" " + _b(name) + b": " + _b(reason))
