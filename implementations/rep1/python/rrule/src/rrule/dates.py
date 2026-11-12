"""Proleptic Gregorian calendar arithmetic on integer day numbers.

A *day number* counts days from 0001-01-01, which is day 0 and a Monday, so
``day_number % 7`` is the weekday (Monday = 0 ... Sunday = 6).  All
conversions are closed-form (O(1)) using the 400-year cycle; nothing here uses
the standard library's date or calendar routines.
"""

from __future__ import annotations

MIN_YEAR = 1
MAX_YEAR = 9999

DAYS_PER_400Y = 146097

# Cumulative days before each month (index 1..12; index 13 is the year length).
CUMULATIVE_DAYS = (
    (0, 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365),
    (0, 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366),
)
MONTH_DAYS = (
    (0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31),
    (0, 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31),
)


def is_leap(year: int) -> bool:
    """Return True if *year* is a Gregorian leap year."""
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)


def year_length(year: int) -> int:
    """Number of days in *year* (365 or 366)."""
    return 366 if is_leap(year) else 365


def month_length(year: int, month: int) -> int:
    """Number of days in *month* (1-12) of *year*."""
    return MONTH_DAYS[is_leap(year)][month]


def days_before_year(year: int) -> int:
    """Day number of 1 January of *year*."""
    y = year - 1
    return y * 365 + y // 4 - y // 100 + y // 400


def days_before_month(year: int, month: int) -> int:
    """Number of days of *year* preceding the first of *month* (1-12)."""
    return CUMULATIVE_DAYS[is_leap(year)][month]


def to_day_number(year: int, month: int, day: int) -> int:
    """Day number of the given calendar date."""
    return days_before_year(year) + CUMULATIVE_DAYS[is_leap(year)][month] + day - 1


def from_day_number(n: int) -> tuple[int, int, int]:
    """Calendar date ``(year, month, day)`` of day number *n* (any integer)."""
    cycle, r = divmod(n, DAYS_PER_400Y)
    y0 = (r - r // 1460 + r // 36524 - r // 146096) // 365  # 0-based year in cycle
    year = cycle * 400 + y0 + 1
    doy = n - days_before_year(year)  # 0-based day of year
    cum = CUMULATIVE_DAYS[is_leap(year)]
    month = (doy >> 5) + 1
    if doy >= cum[month + 1]:
        month += 1
    return year, month, doy - cum[month] + 1


def weekday(year: int, month: int, day: int) -> int:
    """Weekday of a date, Monday = 0 ... Sunday = 6."""
    return to_day_number(year, month, day) % 7


#: Day number of 31 December 9999, the last day the expansion may produce.
LAST_DAY = days_before_year(MAX_YEAR + 1) - 1
