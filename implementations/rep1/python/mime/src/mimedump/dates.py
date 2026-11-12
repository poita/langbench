"""``Date`` header parsing and UTC rendering (all in closed form)."""

from __future__ import annotations

import re
from dataclasses import dataclass

from .lexical import skip_comment
from .textutil import ascii_lower

_DAYS = frozenset({"mon", "tue", "wed", "thu", "fri", "sat", "sun"})
_MONTHS = {
    m: k for k, m in enumerate(
        ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"), 1
    )
}
_ZONES = {
    "ut": 0, "gmt": 0, "z": 0,
    "est": -300, "edt": -240, "cst": -360, "cdt": -300,
    "mst": -420, "mdt": -360, "pst": -480, "pdt": -420,
}
_SEPARATORS = re.compile(r"[ \t,]+")
_DAY = re.compile(r"[0-9]{1,2}")
_YEAR = re.compile(r"[0-9]{2,4}")
_TIME = re.compile(r"([0-9]{1,2}):([0-9]{1,2})(?::([0-9]{1,2}))?")
_NUMERIC_ZONE = re.compile(r"([+-])([0-9]{2})([0-9]{2})")


@dataclass(frozen=True, slots=True)
class ParsedDate:
    """A valid date: seconds since the Unix epoch and the zone offset."""

    epoch: int
    offset_minutes: int

    @property
    def utc(self) -> str:
        """The instant as ``YYYY-MM-DDTHH:MM:SSZ``."""
        days, secs = divmod(self.epoch, 86400)
        y, m, d = civil_from_days(days)
        return (
            f"{y:04d}-{m:02d}-{d:02d}T"
            f"{secs // 3600:02d}:{secs % 3600 // 60:02d}:{secs % 60:02d}Z"
        )

    @property
    def offset(self) -> str:
        """The zone offset as ``±HHMM`` (more digits if the hours need them)."""
        sign = "-" if self.offset_minutes < 0 else "+"
        mins = abs(self.offset_minutes)
        return f"{sign}{mins // 60:02d}{mins % 60:02d}"


def days_from_civil(y: int, m: int, d: int) -> int:
    """Days from 1970-01-01 to the proleptic Gregorian date *y*-*m*-*d*."""
    y -= m <= 2
    era = y // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def civil_from_days(z: int) -> tuple[int, int, int]:
    """Inverse of :func:`days_from_civil`: ``(year, month, day)``."""
    z += 719468
    era = z // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + 3 if mp < 10 else mp - 9
    return y + (m <= 2), m, d


def _is_leap(y: int) -> bool:
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


def _days_in_month(y: int, m: int) -> int:
    if m == 2:
        return 29 if _is_leap(y) else 28
    return 30 if m in (4, 6, 9, 11) else 31


def _strip_comments(s: str) -> str:
    if "(" not in s:
        return s
    out: list[str] = []
    pos = 0
    while True:
        i = s.find("(", pos)
        if i < 0:
            out.append(s[pos:])
            return "".join(out)
        out.append(s[pos:i])
        pos = skip_comment(s, i)


def parse_date(raw: str) -> ParsedDate | None:
    """Parse a raw ``Date`` value; return ``None`` when it is not valid."""
    tokens = [t for t in _SEPARATORS.split(_strip_comments(raw)) if t]
    if tokens and ascii_lower(tokens[0]) in _DAYS:
        tokens = tokens[1:]
    if len(tokens) < 4:
        return None
    day_s, month_s, year_s, time_s = tokens[:4]
    if not _DAY.fullmatch(day_s):
        return None
    day = int(day_s)
    month = _MONTHS.get(ascii_lower(month_s))
    if not 1 <= day <= 31 or month is None or not _YEAR.fullmatch(year_s):
        return None
    year = int(year_s)
    if len(year_s) == 2:
        year += 1900 if year >= 50 else 2000
    elif len(year_s) == 3:
        year += 1900
    if not 1 <= year <= 9999:
        return None
    tm = _TIME.fullmatch(time_s)
    if tm is None:
        return None
    hh, mm, ss = int(tm.group(1)), int(tm.group(2)), int(tm.group(3) or 0)
    if hh > 23 or mm > 59 or ss > 60:
        return None
    offset = 0
    if len(tokens) > 4:
        zone = tokens[4]
        zm = _NUMERIC_ZONE.fullmatch(zone)
        if zm:
            offset = (1 if zm.group(1) == "+" else -1) * (int(zm.group(2)) * 60 + int(zm.group(3)))
        else:
            offset = _ZONES.get(ascii_lower(zone), 0)
    if day > _days_in_month(year, month):
        return None
    epoch = days_from_civil(year, month, day) * 86400 + hh * 3600 + mm * 60 + ss - offset * 60
    return ParsedDate(epoch, offset)
