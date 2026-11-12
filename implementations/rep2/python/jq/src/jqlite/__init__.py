"""jqlite: an interpreter for a subset of the jq filter language.

Typical use::

    >>> import jqlite
    >>> f = jqlite.compile_filter(".users | map(select(.age >= 30)) | length")
    >>> doc = jqlite.loads('{"users":[{"age":31},{"age":20}]}')
    >>> [jqlite.dumps(x) for x in f.run(doc)]
    ['1']

Public API
----------
``compile_filter(source)``  parse and compile a filter into a :class:`Filter`.
``Filter.run(value)``       lazily iterate over the filter's outputs.
``Filter.all(value)``       collect the outputs into a list.
``run(source, value)``      one-shot convenience.
``loads(text)``/``dumps(value)``  the bundled JSON reader and compact writer.
``JQError``                 runtime error (what ``?`` catches).
``JQSyntaxError``           the filter text is invalid.
``JSONDecodeError``         the JSON text is invalid.

Values are ``None``/``bool``/``float``/``str``/``list``/:class:`Obj`; use
:func:`from_native` / :func:`to_native` to convert from and to ordinary Python data.
"""

from __future__ import annotations

from typing import Any, Iterator, List

from .compiler import compile_node
from .errors import JQError, JQSyntaxError, JSONDecodeError
from .jsonio import dumps, loads
from .parser import parse
from .runtime import Code
from .values import Obj, compare, equals, from_native, sort_key, to_native, type_name

__version__ = "0.1.0"

__all__ = [
    "Filter",
    "JQError",
    "JQSyntaxError",
    "JSONDecodeError",
    "Obj",
    "compare",
    "compile_filter",
    "dumps",
    "equals",
    "from_native",
    "loads",
    "run",
    "sort_key",
    "to_native",
    "type_name",
]


class Filter:
    """A compiled jq filter, reusable across inputs."""

    __slots__ = ("source", "_code")

    def __init__(self, source: str) -> None:
        self.source = source
        self._code: Code = compile_node(parse(source))

    def run(self, value: Any) -> Iterator[Any]:
        """Lazily yield the filter's outputs for ``value``.

        :class:`JQError` is raised when evaluation reaches an uncaught error;
        outputs produced before it have already been yielded.
        """
        return iter(self._code.gen(value, None))

    def all(self, value: Any) -> List[Any]:
        """All outputs for ``value`` as a list (raises :class:`JQError` on error)."""
        return list(self._code.gen(value, None))

    def __repr__(self) -> str:
        return f"Filter({self.source!r})"


def compile_filter(source: str) -> Filter:
    """Parse and compile ``source``; raises :class:`JQSyntaxError` if invalid."""
    return Filter(source)


def run(source: str, value: Any) -> List[Any]:
    """Compile ``source`` and return all of its outputs for ``value``."""
    return Filter(source).all(value)
