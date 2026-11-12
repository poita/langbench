"""The thirteen built-in filters."""

from __future__ import annotations

import re
import string

from .errors import TemplateTypeError
from .values import UNDEFINED, WHITESPACE, is_number, sequence, to_str

_UPPER = str.maketrans(string.ascii_lowercase, string.ascii_uppercase)
_LOWER = str.maketrans(string.ascii_uppercase, string.ascii_lowercase)
_ESCAPE = str.maketrans(
    {"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&#34;", "'": "&#39;"}
)
_INTEGER_TEXT = re.compile(r"[+-]?[0-9]+")
_DECIMAL_TEXT = re.compile(r"[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?")


def _upper(value):
    return to_str(value).translate(_UPPER)


def _lower(value):
    return to_str(value).translate(_LOWER)


def _trim(value):
    return to_str(value).strip(WHITESPACE)


def _escape(value):
    return to_str(value).translate(_ESCAPE)


def _replace(value, old, new):
    return to_str(value).replace(to_str(old), to_str(new))


def _length(value):
    if type(value) in (str, list, dict):
        return len(value)
    raise TemplateTypeError("length of a value that has none")


def _int(value):
    cls = type(value)
    if cls is int:
        return value
    if cls is bool:
        return int(value)
    if cls is float:
        return int(value)
    if cls is str:
        text = value.strip(WHITESPACE)
        if _INTEGER_TEXT.fullmatch(text):
            return int(text)
        if _DECIMAL_TEXT.fullmatch(text):
            try:
                return int(float(text))
            except (OverflowError, ValueError):
                return 0
    return 0


def _join(value, sep=""):
    separator = to_str(sep)
    return separator.join([to_str(item) for item in sequence(value)])


def _first(value):
    items = sequence(value)
    return items[0] if items else UNDEFINED


def _last(value):
    items = sequence(value)
    return items[-1] if items else UNDEFINED


def _reverse(value):
    if type(value) is str:
        return value[::-1]
    return sequence(value)[::-1]


def _sort(value):
    items = sequence(value)
    if all(is_number(item) for item in items):
        return sorted(items)
    if all(type(item) is str for item in items):
        return sorted(items, key=lambda s: s.translate(_LOWER))
    raise TemplateTypeError("cannot sort a mixed or unsortable sequence")


def _default(value, fallback=""):
    return fallback if value is UNDEFINED else value


#: name -> (function, minimum extra arguments, maximum extra arguments)
FILTERS = {
    "upper": (_upper, 0, 0),
    "lower": (_lower, 0, 0),
    "trim": (_trim, 0, 0),
    "escape": (_escape, 0, 0),
    "replace": (_replace, 2, 2),
    "length": (_length, 0, 0),
    "int": (_int, 0, 0),
    "join": (_join, 0, 1),
    "first": (_first, 0, 0),
    "last": (_last, 0, 0),
    "reverse": (_reverse, 0, 0),
    "sort": (_sort, 0, 0),
    "default": (_default, 0, 1),
}

FILTER_NAMES = frozenset(FILTERS)
