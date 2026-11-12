"""jqlite: an interpreter for a subset of the jq language.

Public API
----------
``compile(source)``
    Parse and compile a filter into a reusable :class:`Filter`.
``run(source, document)``
    Evaluate a filter against a JSON document (text); yields result values.
``loads(text)`` / ``dumps(value)``
    The hand-written JSON parser and compact serializer.
``JQError``, ``JQSyntaxError``, ``JSONDecodeError``
    Exceptions.

Values are ``None``, ``bool``, ``float``, ``str``, ``list`` and
:class:`Obj` (an insertion-ordered ``dict``); use :func:`from_python` /
:func:`to_python` to convert from / to ordinary Python data.
"""

from __future__ import annotations

from typing import Any, Iterator

from .errors import JQError, JQSyntaxError, JSONDecodeError
from .interp import compile_node
from .jsonio import dumps, loads
from .parser import parse
from .values import Obj, from_python, sort_key, to_python

__all__ = [
    "Filter", "JQError", "JQSyntaxError", "JSONDecodeError", "Obj",
    "compile", "dumps", "from_python", "loads", "run", "sort_key", "to_python",
]
__version__ = "1.0.0"


class Filter:
    """A compiled jq filter.

    >>> list(Filter(".a[] | . * 2").run(loads('{"a":[1,2]}')))
    [2.0, 4.0]
    """

    def __init__(self, source: str) -> None:
        self.source = source
        self._gen, _ = compile_node(parse(source))

    def run(self, value: Any) -> Iterator[Any]:
        """Lazily yield the filter's outputs for ``value`` (a jq value).

        Raises :class:`JQError` at the point in the stream where evaluation
        fails; outputs before it have already been yielded.
        """
        yield from self._gen(value, None)

    def run_text(self, document: str) -> Iterator[str]:
        """Parse ``document`` as JSON and yield each output as compact JSON."""
        for v in self.run(loads(document)):
            yield dumps(v)

    def __repr__(self) -> str:
        return f"Filter({self.source!r})"


def compile(source: str) -> Filter:  # noqa: A001 - mirrors ``re.compile``
    """Compile filter text into a :class:`Filter`."""
    return Filter(source)


def run(source: str, document: str) -> Iterator[Any]:
    """Evaluate ``source`` on the JSON text ``document``; yield output values."""
    return Filter(source).run(loads(document))
