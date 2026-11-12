"""Scalar literals: integers, floats, booleans and date-times.

Every function takes the literal text exactly as written in the document and
returns a :class:`~tomlcodec.model.Scalar` holding its canonical text, or
raises :class:`~tomlcodec.errors.TomlDecodeError`.  Digits are always ASCII
(explicit ``[0-9]`` classes; never ``\\d``).
"""

from __future__ import annotations

import re

from .errors import TomlDecodeError
from .model import (
    BOOL,
    DATE_LOCAL,
    DATETIME,
    DATETIME_LOCAL,
    FLOAT,
    INTEGER,
    TIME_LOCAL,
    Scalar,
)

INT64_MIN = -(2**63)
INT64_MAX = 2**63 - 1

_DEC_INT = re.compile(r"[+-]?(?:0|[1-9](?:_?[0-9])*)")
_HEX_INT = re.compile(r"0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*")
_OCT_INT = re.compile(r"0o[0-7](?:_?[0-7])*")
_BIN_INT = re.compile(r"0b[01](?:_?[01])*")
_FLOAT = re.compile(
    r"[+-]?(?:0|[1-9](?:_?[0-9])*)"
    r"(?:\.[0-9](?:_?[0-9])*(?:[eE][+-]?[0-9](?:_?[0-9])*)?"
    r"|[eE][+-]?[0-9](?:_?[0-9])*)"
)
_SPECIAL = re.compile(r"([+-]?)(inf|nan)")

_DATE = r"(?P<year>[0-9]{4})-(?P<month>[0-9]{2})-(?P<day>[0-9]{2})"
_TIME = (
    r"(?P<hour>[0-9]{2}):(?P<minute>[0-9]{2}):(?P<second>[0-9]{2})"
    r"(?:\.(?P<frac>[0-9]+))?"
)
_OFFSET = r"(?:(?P<zulu>[Zz])|(?P<offset>[+-][0-9]{2}:[0-9]{2}))"

#: Matches a date, optionally followed by a complete time and offset.
DATETIME_RE = re.compile(rf"{_DATE}(?:[Tt ]{_TIME}{_OFFSET}?)?")
#: Matches a bare time of day.
TIME_RE = re.compile(_TIME)

_DAYS_IN_MONTH = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)


def _error(kind: str, text: str) -> TomlDecodeError:
    return TomlDecodeError(f"invalid {kind}: {text[:40]!r}")


def parse_integer(text: str) -> Scalar | None:
    """Parse an integer literal in any base; ``None`` if ``text`` isn't one.

    Raises :class:`TomlDecodeError` if it is an integer outside the signed
    64-bit range.
    """
    if _DEC_INT.fullmatch(text):
        digits = text.replace("_", "")
        if len(digits) > 21:  # cannot fit in 64 bits; avoid huge conversions
            raise _error("integer (out of range)", text)
        value = int(digits, 10)
    elif _HEX_INT.fullmatch(text):
        value = int(text[2:].replace("_", ""), 16)
    elif _OCT_INT.fullmatch(text):
        value = int(text[2:].replace("_", ""), 8)
    elif _BIN_INT.fullmatch(text):
        value = int(text[2:].replace("_", ""), 2)
    else:
        return None
    if not INT64_MIN <= value <= INT64_MAX:
        raise _error("integer (out of range)", text)
    return Scalar(INTEGER, str(value))


def format_float(value: float) -> str:
    """Render a double in the canonical form (17 significant digits)."""
    if value != value:
        return "nan"
    if value == float("inf"):
        return "inf"
    if value == float("-inf"):
        return "-inf"
    return f"{value:.16e}"


def parse_float(text: str) -> Scalar | None:
    """Parse a float literal; ``None`` if ``text`` isn't one."""
    m = _SPECIAL.fullmatch(text)
    if m:
        if m.group(2) == "nan":
            return Scalar(FLOAT, "nan")
        return Scalar(FLOAT, "-inf" if m.group(1) == "-" else "inf")
    if _FLOAT.fullmatch(text):
        # float() rounds correctly and saturates to inf / 0.0 on overflow.
        return Scalar(FLOAT, format_float(float(text.replace("_", ""))))
    return None


def parse_bool(text: str) -> Scalar | None:
    """Parse ``true`` / ``false``; ``None`` for anything else."""
    if text == "true" or text == "false":
        return Scalar(BOOL, text)
    return None


def _is_leap(year: int) -> bool:
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)


def _check_date(year: str, month: str, day: str) -> str:
    y, m, d = int(year), int(month), int(day)
    if y < 1 or not 1 <= m <= 12:
        raise _error("date", f"{year}-{month}-{day}")
    limit = 29 if m == 2 and _is_leap(y) else _DAYS_IN_MONTH[m - 1]
    if not 1 <= d <= limit:
        raise _error("date", f"{year}-{month}-{day}")
    return f"{year}-{month}-{day}"


def _check_time(m: re.Match[str]) -> str:
    hour, minute, second, frac = m.group("hour", "minute", "second", "frac")
    if int(hour) > 23 or int(minute) > 59 or int(second) > 59:
        raise _error("time", m.group())
    text = f"{hour}:{minute}:{second}"
    if frac:
        frac = frac.rstrip("0")
        if frac:
            text += "." + frac
    return text


def datetime_from_match(m: re.Match[str]) -> Scalar:
    """Validate a :data:`DATETIME_RE` match and canonicalise it."""
    date = _check_date(*m.group("year", "month", "day"))
    if m.group("hour") is None:
        return Scalar(DATE_LOCAL, date)
    text = date + "T" + _check_time(m)
    if m.group("zulu"):
        return Scalar(DATETIME, text + "Z")
    offset = m.group("offset")
    if offset is None:
        return Scalar(DATETIME_LOCAL, text)
    if int(offset[1:3]) > 23 or int(offset[4:6]) > 59:
        raise _error("offset", offset)
    if offset[1:] == "00:00":
        offset = "Z"
    return Scalar(DATETIME, text + offset)


def time_from_match(m: re.Match[str]) -> Scalar:
    """Validate a :data:`TIME_RE` match and canonicalise it."""
    return Scalar(TIME_LOCAL, _check_time(m))


def parse_scalar_token(token: str) -> Scalar:
    """Parse a bare (unquoted, non-date) literal token.

    Raises :class:`TomlDecodeError` if the token is not a valid integer,
    float or boolean.
    """
    for parser in (parse_integer, parse_float, parse_bool):
        result = parser(token)
        if result is not None:
            return result
    raise _error("value", token)
