"""Conversion of a document tree to plain Python objects."""

from __future__ import annotations

import datetime as _dt

from .model import Scalar


def to_python(node: object) -> object:
    """Convert a tree from :func:`tomlcodec.loads` to native Python objects.

    Tables become ``dict``, arrays ``list``, strings ``str``, integers ``int``,
    floats ``float``, booleans ``bool`` and the four date/time types the
    matching :mod:`datetime` objects. Fractional seconds are truncated to
    microseconds, the precision :mod:`datetime` can hold; use the tree itself
    (whose scalars keep their full text) when that matters.
    """
    if isinstance(node, Scalar):
        return _scalar(node)
    if isinstance(node, dict):
        return {k: to_python(v) for k, v in node.items()}
    if isinstance(node, list):
        return [to_python(v) for v in node]
    raise TypeError(f"not a document node: {type(node).__name__}")


def _time(text: str) -> _dt.time:
    whole, _, frac = text.partition(".")
    h, m, s = (int(p) for p in whole.split(":"))
    return _dt.time(h, m, s, int(frac[:6].ljust(6, "0")) if frac else 0)


def _scalar(s: Scalar) -> object:
    kind, text = s
    if kind == "string":
        return text
    if kind == "integer":
        return int(text)
    if kind == "float":
        return float(text)
    if kind == "bool":
        return text == "true"
    if kind == "date-local":
        return _dt.date.fromisoformat(text)
    if kind == "time-local":
        return _time(text)
    date, _, rest = text.partition("T")
    if kind == "datetime-local":
        return _dt.datetime.combine(_dt.date.fromisoformat(date), _time(rest))
    # offset datetime
    if rest.endswith("Z"):
        tz = _dt.timezone.utc
        rest = rest[:-1]
    else:
        i = max(rest.rfind("+"), rest.rfind("-"))
        sign = -1 if rest[i] == "-" else 1
        hh, mm = rest[i + 1 :].split(":")
        tz = _dt.timezone(sign * _dt.timedelta(hours=int(hh), minutes=int(mm)))
        rest = rest[:i]
    return _dt.datetime.combine(_dt.date.fromisoformat(date), _time(rest), tz)
