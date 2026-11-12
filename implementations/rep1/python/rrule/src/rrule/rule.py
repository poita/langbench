"""Data model and parser for recurrence rules and input lines."""

from __future__ import annotations

from dataclasses import dataclass
from typing import NamedTuple

from . import dates

FREQUENCIES = ("YEARLY", "MONTHLY", "WEEKLY", "DAILY")
WEEKDAY_CODES = ("MO", "TU", "WE", "TH", "FR", "SA", "SU")
_WEEKDAY_INDEX = {code: i for i, code in enumerate(WEEKDAY_CODES)}


class RuleError(ValueError):
    """Raised when a rule or input line cannot be parsed."""


class DateTime(NamedTuple):
    """A floating (time-zone-less) date-time.

    Tuples compare chronologically.  ``str()``/``isoformat()`` give the
    ``YYYYMMDDTHHMMSS`` form used by RFC 5545 and by the command line tool.
    """

    year: int
    month: int
    day: int
    hour: int = 0
    minute: int = 0
    second: int = 0

    def isoformat(self) -> str:
        return "%04d%02d%02dT%02d%02d%02d" % self

    @classmethod
    def parse(cls, text: str) -> "DateTime":
        """Parse ``YYYYMMDDTHHMMSS``, validating the calendar date and time."""
        if len(text) != 15 or text[8] != "T" or not (text[:8] + text[9:]).isdigit():
            raise RuleError(f"invalid date-time {text!r}")
        year, month, day = int(text[0:4]), int(text[4:6]), int(text[6:8])
        hour, minute, second = int(text[9:11]), int(text[11:13]), int(text[13:15])
        if not (dates.MIN_YEAR <= year <= dates.MAX_YEAR and 1 <= month <= 12):
            raise RuleError(f"invalid date in {text!r}")
        if not 1 <= day <= dates.month_length(year, month):
            raise RuleError(f"invalid date in {text!r}")
        if hour > 23 or minute > 59 or second > 59:
            raise RuleError(f"invalid time in {text!r}")
        return cls(year, month, day, hour, minute, second)

    __str__ = isoformat


@dataclass(frozen=True)
class Rule:
    """A recurrence rule.

    Attributes mirror the RRULE parts.  ``by_*`` fields are tuples (empty when
    the part is absent).  ``by_day`` holds ``(ordinal, weekday)`` pairs with
    weekday Monday = 0 and ordinal 0 meaning "every such weekday".
    ``wkst`` is the week start weekday (Monday = 0).
    """

    freq: str
    interval: int = 1
    count: int | None = None
    until: DateTime | None = None
    wkst: int = 0
    by_month: tuple[int, ...] = ()
    by_month_day: tuple[int, ...] = ()
    by_year_day: tuple[int, ...] = ()
    by_week_no: tuple[int, ...] = ()
    by_day: tuple[tuple[int, int], ...] = ()
    by_set_pos: tuple[int, ...] = ()

    def __post_init__(self) -> None:
        if self.freq not in FREQUENCIES:
            raise RuleError(f"unsupported FREQ {self.freq!r}")

    @classmethod
    def parse(cls, text: str) -> "Rule":
        """Parse an RRULE value such as ``FREQ=MONTHLY;BYDAY=-1FR;COUNT=10``."""
        fields: dict[str, object] = {}
        freq = None
        for part in text.split(";"):
            name, sep, value = part.partition("=")
            if not sep or not value:
                raise RuleError(f"malformed rule part {part!r}")
            if name == "FREQ":
                freq = value
            elif name == "INTERVAL":
                fields["interval"] = _int(value)
            elif name == "COUNT":
                fields["count"] = _int(value)
            elif name == "UNTIL":
                fields["until"] = DateTime.parse(value)
            elif name == "WKST":
                fields["wkst"] = _weekday(value)
            elif name == "BYMONTH":
                fields["by_month"] = _int_list(value)
            elif name == "BYMONTHDAY":
                fields["by_month_day"] = _int_list(value)
            elif name == "BYYEARDAY":
                fields["by_year_day"] = _int_list(value)
            elif name == "BYWEEKNO":
                fields["by_week_no"] = _int_list(value)
            elif name == "BYDAY":
                fields["by_day"] = tuple(_byday(v) for v in value.split(","))
            elif name == "BYSETPOS":
                fields["by_set_pos"] = _int_list(value)
            else:
                raise RuleError(f"unsupported rule part {name!r}")
        if freq is None:
            raise RuleError("FREQ is required")
        return cls(freq=freq, **fields)  # type: ignore[arg-type]


class Line(NamedTuple):
    """One parsed input line: ``<DTSTART> <RRULE> <N>``."""

    dtstart: DateTime
    rule: Rule
    limit: int


def parse_line(line: str) -> Line:
    """Parse an input line of the command-line format."""
    fields = line.split(" ")
    if len(fields) != 3:
        raise RuleError(f"expected 'DTSTART RRULE N', got {line!r}")
    return Line(DateTime.parse(fields[0]), Rule.parse(fields[1]), _int(fields[2]))


def _int(text: str) -> int:
    try:
        return int(text)
    except ValueError:
        raise RuleError(f"invalid integer {text!r}") from None


def _int_list(text: str) -> tuple[int, ...]:
    return tuple(_int(v) for v in text.split(","))


def _weekday(code: str) -> int:
    try:
        return _WEEKDAY_INDEX[code]
    except KeyError:
        raise RuleError(f"invalid weekday {code!r}") from None


def _byday(text: str) -> tuple[int, int]:
    return (_int(text[:-2]) if len(text) > 2 else 0), _weekday(text[-2:])
