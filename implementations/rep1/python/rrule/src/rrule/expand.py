"""Recurrence expansion.

The rule is evaluated period by period (a year, a month, a week or a day).
Every candidate day of a period is tested against each filter present in the
rule, ``BYSETPOS`` then selects among the surviving days, and the results are
emitted in order until a limit is reached.  Each candidate day costs O(1);
per-year and per-range values (week numbering, ordinal weekday designations)
are computed once for the year or range.

Dates are integer day numbers (see :mod:`rrule.dates`) internally.
"""

from __future__ import annotations

from collections.abc import Iterator

from . import dates
from .rule import DateTime, Rule

_LAST_DAY = dates.LAST_DAY


def occurrences(dtstart: DateTime, rule: Rule, limit: int | None = None) -> Iterator[DateTime]:
    """Yield the occurrences of *rule* starting at *dtstart*, in order.

    Iteration ends after ``rule.count`` occurrences, after *limit* occurrences
    (when given), when an occurrence is later than ``rule.until``, or when the
    expansion runs past 31 December 9999 -- whichever comes first.  The
    iterator is lazy, so an unbounded rule can be consumed incrementally.
    """
    max_out = None
    for bound in (rule.count, limit):
        if bound is not None and (max_out is None or bound < max_out):
            max_out = bound
    if max_out is not None and max_out <= 0:
        return

    hour, minute, second = dtstart[3:6]
    tod = (hour, minute, second)
    freq = rule.freq
    interval = rule.interval
    wkst = rule.wkst
    dt_day = dates.to_day_number(dtstart.year, dtstart.month, dtstart.day)

    # Last day number that may be emitted (None: unbounded); an occurrence on
    # the UNTIL date is only kept if its time of day (DTSTART's) is not later.
    cut = None
    if rule.until is not None:
        u = rule.until
        cut = dates.to_day_number(u.year, u.month, u.day)
        if tod > tuple(u[3:6]):
            cut -= 1

    # ---- step 1: defaults derived from DTSTART ------------------------------
    by_month = set(rule.by_month)
    by_month_day = set(rule.by_month_day)
    by_year_day = set(rule.by_year_day)
    by_week_no = set(rule.by_week_no)
    by_day = rule.by_day
    if not (by_month_day or by_year_day or by_week_no or by_day):
        if freq == "YEARLY":
            if not by_month:
                by_month = {dtstart.month}
            by_month_day = {dtstart.day}
        elif freq == "MONTHLY":
            by_month_day = {dtstart.day}
        elif freq == "WEEKLY":
            by_day = ((0, dt_day % 7),)

    plain_days = {wd for n, wd in by_day if n == 0}
    ordinal_codes = [(n, wd) for n, wd in by_day if n != 0]
    set_pos = rule.by_set_pos

    has_month = bool(by_month)
    has_md = bool(by_month_day)
    has_yd = bool(by_year_day)
    has_wn = bool(by_week_no)
    has_wd = bool(plain_days)
    has_ord = bool(ordinal_codes)
    need_year = has_yd or has_wn
    wn_last = -1 in by_week_no
    wn_first = 1 in by_week_no

    year_cache: tuple = (0,)  # (year, jan1, length, s, weeks, case-b match)

    def year_info(year: int) -> tuple:
        jan1 = dates.days_before_year(year)
        length = dates.year_length(year)
        first = (wkst - jan1) % 7
        s = first if first < 4 else first - 7
        span = length - s
        weeks = span // 7 + (1 if span % 7 >= 4 else 0)
        if s > 0:  # days before week 1 exist: week number of the previous year
            prev_len = dates.year_length(year - 1)
            prev_first = (wkst - (jan1 - prev_len)) % 7
            prev_s = prev_first if prev_first < 4 else prev_first - 7
            if prev_s < 0:
                prev_span = prev_len - prev_s
                p = prev_span // 7 + (1 if prev_span % 7 >= 4 else 0)
            else:
                p = 52 + (1 if span % 7 >= 4 else 0)
            b_match = wn_last or p in by_week_no
        else:
            b_match = False
        return year, jan1, length, s, weeks, b_match

    # ---- period enumeration ---------------------------------------------------
    y0, m0 = dtstart.year, dtstart.month
    week_a = dt_day - (dt_day - wkst) % 7  # most recent WKST on or before DTSTART
    emitted = 0
    k = 0
    while True:
        # Build this period's segments: runs of days inside one month, as
        # (year, month, day-of-month of first day, number of days, first day number).
        if freq == "YEARLY":
            year = y0 + k * interval
            if year > dates.MAX_YEAR:
                return
            jan1 = dates.days_before_year(year)
            first_day = jan1
            if cut is not None and first_day > cut:
                return
            segments = []
            leap = dates.is_leap(year)
            for month in range(1, 13):
                length = dates.MONTH_DAYS[leap][month]
                segments.append((year, month, 1, length, jan1 + dates.CUMULATIVE_DAYS[leap][month]))
            ord_ranges = (
                [(s[4], s[4] + s[3]) for s in segments if s[1] in by_month]
                if by_month
                else [(jan1, jan1 + dates.year_length(year))]
            )
        elif freq == "MONTHLY":
            total = y0 * 12 + (m0 - 1) + k * interval
            year, month = divmod(total, 12)
            month += 1
            if year > dates.MAX_YEAR:
                return
            length = dates.month_length(year, month)
            first_day = dates.days_before_year(year) + dates.days_before_month(year, month)
            if cut is not None and first_day > cut:
                return
            segments = [(year, month, 1, length, first_day)]
            ord_ranges = [(first_day, first_day + length)]
        else:
            if freq == "DAILY":
                first_day = dt_day + k * interval
                end = first_day + 1
            elif k == 0:  # WEEKLY
                first_day = dt_day
                end = week_a + 7
            else:
                first_day = week_a + 7 * k * interval
                end = first_day + 7
            if first_day > _LAST_DAY or (cut is not None and first_day > cut):
                return
            if end > _LAST_DAY + 1:
                end = _LAST_DAY + 1
            segments = []
            day = first_day
            while day < end:
                year, month, dom = dates.from_day_number(day)
                n = min(end - day, dates.month_length(year, month) - dom + 1)
                segments.append((year, month, dom, n, day))
                day += n
            ord_ranges = ()
        k += 1

        # ---- step 5: days designated by ordinal BYDAY codes -----------------
        ord_days: set[int] = set()
        if has_ord:
            for lo, hi in ord_ranges:
                for n, wd in ordinal_codes:
                    if n > 0:
                        d = lo + (wd - lo) % 7 + 7 * (n - 1)
                        if d < hi:
                            ord_days.add(d)
                    else:
                        d = hi - 1 - ((hi - 1) - wd) % 7 + 7 * (n + 1)
                        if d >= lo:
                            ord_days.add(d)

        # ---- step 3: test every candidate day -------------------------------
        kept: list[int] = []
        for year, month, d0, n, start in segments:
            if need_year:
                if year_cache[0] != year:
                    year_cache = year_info(year)
                _, jan1, ylen, s, weeks, b_match = year_cache
            mlen = dates.MONTH_DAYS[dates.is_leap(year)][month] if has_md else 0
            month_ok = month in by_month if has_month else True
            for i in range(n):
                day = start + i
                if not month_ok:
                    continue
                if has_wd and day % 7 not in plain_days:
                    continue
                if has_ord and day not in ord_days:
                    continue
                if has_md:
                    dom = d0 + i
                    if dom not in by_month_day and dom - mlen - 1 not in by_month_day:
                        continue
                if has_yd:
                    yd = day - jan1 + 1
                    if yd not in by_year_day and yd - ylen - 1 not in by_year_day:
                        continue
                if has_wn:
                    idx = day - jan1
                    if idx < s:
                        if not b_match:
                            continue
                    else:
                        w = (idx - s) // 7 + 1
                        if w > weeks:
                            if not wn_first:
                                continue
                        elif w not in by_week_no and w - weeks - 1 not in by_week_no:
                            continue
                kept.append(day)

        # ---- step 6: BYSETPOS -------------------------------------------------
        if set_pos:
            count = len(kept)
            chosen = set()
            for p in set_pos:
                idx = p - 1 if p > 0 else count + p
                if 0 <= idx < count:
                    chosen.add(idx)
            kept = [kept[i] for i in sorted(chosen)]

        # ---- step 7: emit -----------------------------------------------------
        for day in kept:
            if cut is not None and day > cut:
                return
            if day < dt_day:
                continue
            y, m, d = dates.from_day_number(day)
            yield DateTime(y, m, d, hour, minute, second)
            emitted += 1
            if max_out is not None and emitted >= max_out:
                return

