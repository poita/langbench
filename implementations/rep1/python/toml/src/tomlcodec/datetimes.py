"""Date and time literals, validated and canonicalised as text.

No calendar library is used: the fields are checked arithmetically and the
canonical text is assembled from the original digits.
"""

from __future__ import annotations

import re

#: One regex for every date/time shape. All digits are explicit ``[0-9]``.
DATETIME_RE = re.compile(
    r"""
    (?:(?P<year>[0-9]{4})-(?P<month>[0-9]{2})-(?P<day>[0-9]{2}))
    (?:
        [Tt\ ]
        (?P<dhour>[0-9]{2}):(?P<dmin>[0-9]{2}):(?P<dsec>[0-9]{2})
        (?:\.(?P<dfrac>[0-9]+))?
        (?P<offset>[Zz]|[+-][0-9]{2}:[0-9]{2})?
    )?
    |
    (?:(?P<hour>[0-9]{2}):(?P<min>[0-9]{2}):(?P<sec>[0-9]{2})(?:\.(?P<frac>[0-9]+))?)
    """,
    re.VERBOSE,
)

_DAYS = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)


def _is_leap(year: int) -> bool:
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)


def _date(m: "re.Match[str]") -> str | None:
    year, month, day = int(m["year"]), int(m["month"]), int(m["day"])
    if year < 1 or not 1 <= month <= 12:
        return None
    limit = _DAYS[month - 1] + (1 if month == 2 and _is_leap(year) else 0)
    if not 1 <= day <= limit:
        return None
    return f"{m['year']}-{m['month']}-{m['day']}"


def _time(hour: str, minute: str, second: str, frac: str | None) -> str | None:
    if int(hour) > 23 or int(minute) > 59 or int(second) > 59:
        return None
    text = f"{hour}:{minute}:{second}"
    if frac:
        frac = frac.rstrip("0")
        if frac:
            text += "." + frac
    return text


def _offset(offset: str) -> str | None:
    if offset in ("Z", "z"):
        return "Z"
    if int(offset[1:3]) > 23 or int(offset[4:6]) > 59:
        return None
    if offset[1:] == "00:00":
        return "Z"
    return offset


def canonical_datetime(m: "re.Match[str]") -> tuple[str, str] | None:
    """Turn a :data:`DATETIME_RE` match into ``(type, canonical text)``.

    Returns ``None`` if a field is out of range (month 13, February 30, ...).
    """
    if m["year"] is None:
        text = _time(m["hour"], m["min"], m["sec"], m["frac"])
        return None if text is None else ("time-local", text)
    date = _date(m)
    if date is None:
        return None
    if m["dhour"] is None:
        return ("date-local", date)
    time = _time(m["dhour"], m["dmin"], m["dsec"], m["dfrac"])
    if time is None:
        return None
    if m["offset"] is None:
        return ("datetime-local", f"{date}T{time}")
    off = _offset(m["offset"])
    if off is None:
        return None
    return ("datetime", f"{date}T{time}{off}")
