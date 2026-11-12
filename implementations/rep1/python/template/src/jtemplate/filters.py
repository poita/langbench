"""The thirteen built-in filters.

Each filter is registered in :data:`FILTERS` together with the minimum and
maximum number of extra arguments it accepts.  A filter function receives the
(defined) input value followed by its arguments.  ``default`` is special: it
is the only one that accepts the undefined value, so the interpreter treats
it separately (see :data:`ACCEPTS_UNDEFINED`).
"""

from __future__ import annotations

import re
from typing import Any, Callable, NamedTuple

from .errors import TemplateTypeError
from .values import UNDEFINED, WHITESPACE, is_number, sequence_view, to_str, type_name

_UPPER = str.maketrans("abcdefghijklmnopqrstuvwxyz", "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
_LOWER = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")
_ESCAPES = str.maketrans(
    {"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&#34;", "'": "&#39;"}
)
_INTEGER = re.compile(r"[+-]?[0-9]+")
_DECIMAL = re.compile(r"[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?")


class Filter(NamedTuple):
    func: Callable[..., Any]
    min_args: int
    max_args: int


def ascii_lower(text: str) -> str:
    """Lowercase ASCII letters only."""
    return text.translate(_LOWER)


def _upper(value: Any) -> str:
    return to_str(value).translate(_UPPER)


def _lower(value: Any) -> str:
    return to_str(value).translate(_LOWER)


def _trim(value: Any) -> str:
    return to_str(value).strip(WHITESPACE)


def _escape(value: Any) -> str:
    return to_str(value).translate(_ESCAPES)


def _replace(value: Any, old: Any, new: Any) -> str:
    return to_str(value).replace(to_str(old), to_str(new))


def _length(value: Any) -> int:
    if isinstance(value, (str, list, dict)):
        return len(value)
    raise TemplateTypeError(f"{type_name(value)} has no length")


def _int(value: Any) -> int:
    if isinstance(value, int):  # includes bool
        return int(value)
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        text = value.strip(WHITESPACE)
        if _INTEGER.fullmatch(text):
            return int(text)
        if _DECIMAL.fullmatch(text):
            try:
                return int(float(text))
            except (OverflowError, ValueError):
                return 0
    return 0


def _join(value: Any, sep: Any = "") -> str:
    return to_str(sep).join([to_str(item) for item in sequence_view(value)])


def _first(value: Any) -> Any:
    seq = sequence_view(value)
    return seq[0] if seq else UNDEFINED


def _last(value: Any) -> Any:
    seq = sequence_view(value)
    return seq[-1] if seq else UNDEFINED


def _reverse(value: Any) -> Any:
    if isinstance(value, str):
        return value[::-1]
    return sequence_view(value)[::-1]


def _sort(value: Any) -> list:
    seq = sequence_view(value)
    if all(is_number(item) for item in seq):
        return sorted(seq)
    if all(isinstance(item, str) for item in seq):
        return sorted(seq, key=ascii_lower)
    raise TemplateTypeError("sort needs all numbers or all strings")


def _default(value: Any, fallback: Any = "") -> Any:
    return fallback if value is UNDEFINED else value


FILTERS: dict[str, Filter] = {
    "upper": Filter(_upper, 0, 0),
    "lower": Filter(_lower, 0, 0),
    "trim": Filter(_trim, 0, 0),
    "escape": Filter(_escape, 0, 0),
    "replace": Filter(_replace, 2, 2),
    "length": Filter(_length, 0, 0),
    "int": Filter(_int, 0, 0),
    "join": Filter(_join, 0, 1),
    "first": Filter(_first, 0, 0),
    "last": Filter(_last, 0, 0),
    "reverse": Filter(_reverse, 0, 0),
    "sort": Filter(_sort, 0, 0),
    "default": Filter(_default, 0, 1),
}

#: Names of filters that accept the undefined value as input.
ACCEPTS_UNDEFINED = frozenset({"default"})
