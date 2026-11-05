#!/usr/bin/env python3
"""Reference solver for the `rrule` problem.

Expands RFC 5545 recurrence rules (the subset described in SPEC.md) with the
same semantics as python-dateutil's rrule. All calendar arithmetic (leap
years, weekdays, week numbering) is implemented here from scratch; the
datetime and calendar modules are deliberately not used.
"""
import sys

YEARLY, MONTHLY, WEEKLY, DAILY = 0, 1, 2, 3
FREQS = {'YEARLY': YEARLY, 'MONTHLY': MONTHLY, 'WEEKLY': WEEKLY, 'DAILY': DAILY}
WEEKDAYS = {'MO': 0, 'TU': 1, 'WE': 2, 'TH': 3, 'FR': 4, 'SA': 5, 'SU': 6}
MAX_YEAR = 9999
DIM = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]


# ---------------------------------------------------------------------------
# Proleptic Gregorian calendar arithmetic
# ---------------------------------------------------------------------------
def is_leap(y):
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


def year_len(y):
    return 366 if is_leap(y) else 365


def days_in_month(y, m):
    if m == 2 and is_leap(y):
        return 29
    return DIM[m - 1]


def days_before_year(y):
    y -= 1
    return y * 365 + y // 4 - y // 100 + y // 400


DAYS_BEFORE_MONTH = [0, 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]


def days_before_month(y, m):
    return DAYS_BEFORE_MONTH[m] + (1 if m > 2 and is_leap(y) else 0)


def to_ordinal(y, m, d):
    """Day number with 0001-01-01 = 1 (a Monday)."""
    return days_before_year(y) + days_before_month(y, m) + d


def from_ordinal(n):
    """Inverse of to_ordinal, using the 400/100/4/1-year cycle structure."""
    n -= 1
    n400, n = divmod(n, 146097)
    year = n400 * 400 + 1
    n100, n = divmod(n, 36524)
    n4, n = divmod(n, 1461)
    n1, n = divmod(n, 365)
    year += n100 * 100 + n4 * 4 + n1
    if n1 == 4 or n100 == 4:
        return year - 1, 12, 31
    leap = n1 == 3 and (n4 != 24 or n100 == 3)
    month = (n + 50) >> 5
    preceding = DAYS_BEFORE_MONTH[month] + (1 if month > 2 and leap else 0)
    if preceding > n:
        month -= 1
        preceding -= DIM[month - 1] + (1 if month == 2 and leap else 0)
    return year, month, n - preceding + 1


def weekday_of_ordinal(n):
    """0 = Monday ... 6 = Sunday."""
    return (n + 6) % 7


# ---------------------------------------------------------------------------
# Week numbering (RFC 5545: week 1 is the first week, starting on WKST, that
# contains at least four days of the calendar year).
# ---------------------------------------------------------------------------
def week1_start(y, wkst):
    """Index (day-of-year, zero based, may be negative) of the first day of week 1 of year y."""
    first = (wkst - weekday_of_ordinal(to_ordinal(y, 1, 1))) % 7
    return first if first < 4 else first - 7


def num_weeks(y, wkst):
    wyearlen = year_len(y) - week1_start(y, wkst)
    return wyearlen // 7 + (1 if wyearlen % 7 >= 4 else 0)


class WeekInfo:
    """Which candidate days of a calendar year match BYWEEKNO."""

    def __init__(self, y, wkst, byweekno):
        self.start1 = week1_start(y, wkst)
        self.nweeks = num_weeks(y, wkst)
        # Absolute week numbers (1..nweeks) of year y that are wanted.
        self.wanted = set()
        for n in byweekno:
            k = n if n > 0 else n + self.nweeks + 1
            if 1 <= k <= self.nweeks:
                self.wanted.add(k)
        # Early January days that belong to the last week of the previous year
        # match -1, or the number P that the oracle assigns to that week: the
        # true count of weeks of year y-1 when its week 1 starts in y-2, and
        # otherwise 52 plus one if (yearlen(y) - start1) mod 7 >= 4.
        if week1_start(y - 1, wkst) < 0:
            prev_last = num_weeks(y - 1, wkst)
        else:
            prev_last = 52 + (1 if (year_len(y) - self.start1) % 7 >= 4 else 0)
        self.prev_ok = prev_last in byweekno or -1 in byweekno
        # Late December days that belong to week 1 of the next year.
        self.next_ok = 1 in byweekno

    def matches(self, yday0):
        """yday0: zero-based day of year within year y."""
        if yday0 < self.start1:
            return self.prev_ok
        k = (yday0 - self.start1) // 7 + 1
        if k <= self.nweeks:
            return k in self.wanted
        return self.next_ok


# ---------------------------------------------------------------------------
# Rule parsing
# ---------------------------------------------------------------------------
def parse_dt(s):
    return (int(s[0:4]), int(s[4:6]), int(s[6:8]), int(s[9:11]), int(s[11:13]), int(s[13:15]))


def fmt_dt(y, m, d, hh, mm, ss):
    return '%04d%02d%02dT%02d%02d%02d' % (y, m, d, hh, mm, ss)


class Rule:
    def __init__(self, text, dtstart):
        self.dtstart = dtstart
        self.freq = None
        self.interval = 1
        self.count = None
        self.until = None
        self.wkst = 0
        self.bymonth = None
        self.bymonthday = None
        self.byyearday = None
        self.byweekno = None
        self.byday = None       # set of weekdays (no ordinal)
        self.bynday = None      # list of (weekday, ordinal)
        self.bysetpos = None
        for part in text.split(';'):
            name, value = part.split('=', 1)
            if name == 'FREQ':
                self.freq = FREQS[value]
            elif name == 'INTERVAL':
                self.interval = int(value)
            elif name == 'COUNT':
                self.count = int(value)
            elif name == 'UNTIL':
                self.until = parse_dt(value)
            elif name == 'WKST':
                self.wkst = WEEKDAYS[value]
            elif name == 'BYMONTH':
                self.bymonth = set(int(v) for v in value.split(','))
            elif name == 'BYMONTHDAY':
                self.bymonthday = set(int(v) for v in value.split(','))
            elif name == 'BYYEARDAY':
                self.byyearday = set(int(v) for v in value.split(','))
            elif name == 'BYWEEKNO':
                self.byweekno = set(int(v) for v in value.split(','))
            elif name == 'BYSETPOS':
                self.bysetpos = [int(v) for v in value.split(',')]
            elif name == 'BYDAY':
                plain, ordinal = set(), []
                for v in value.split(','):
                    wd = WEEKDAYS[v[-2:]]
                    if len(v) > 2:
                        ordinal.append((wd, int(v[:-2])))
                    else:
                        plain.add(wd)
                self.byday = plain or None
                self.bynday = ordinal or None
            else:
                raise ValueError('unknown rule part ' + name)
        y, m, d = dtstart[0], dtstart[1], dtstart[2]
        # Default day selectors derived from DTSTART when no day-level part is given.
        if (self.bymonthday is None and self.byyearday is None and self.byweekno is None
                and self.byday is None and self.bynday is None):
            if self.freq == YEARLY:
                if self.bymonth is None:
                    self.bymonth = {m}
                self.bymonthday = {d}
            elif self.freq == MONTHLY:
                self.bymonthday = {d}
            elif self.freq == WEEKLY:
                self.byday = {weekday_of_ordinal(to_ordinal(y, m, d))}
        self.has_filters = (self.bymonth is not None or self.bymonthday is not None
                            or self.byyearday is not None or self.byweekno is not None
                            or self.byday is not None or self.bynday is not None)


def nth_weekday_ordinals(first, last, bynday):
    """Ordinals of the ordinal-qualified weekdays (e.g. 2MO, -1FR) within [first, last]."""
    out = set()
    for wd, n in bynday:
        if n > 0:
            i = first + (n - 1) * 7
            i += (wd - weekday_of_ordinal(i)) % 7
        else:
            i = last + (n + 1) * 7
            i -= (weekday_of_ordinal(i) - wd) % 7
        if first <= i <= last:
            out.add(i)
    return out


def expand(rule, limit):
    """Yields occurrences as (y, m, d, hh, mm, ss) tuples, at most `limit` of them."""
    ds = rule.dtstart
    hh, mm, ss = ds[3], ds[4], ds[5]
    start_ord = to_ordinal(ds[0], ds[1], ds[2])
    dt_key = (start_ord, hh, mm, ss)
    until_key = None
    if rule.until is not None:
        u = rule.until
        until_key = (to_ordinal(u[0], u[1], u[2]), u[3], u[4], u[5])
    freq = rule.freq
    interval = rule.interval
    remaining = rule.count
    emitted = 0
    if limit <= 0 or remaining == 0:
        return

    # Period cursor: (year, month) for YEARLY/MONTHLY, an ordinal for WEEKLY/DAILY.
    year, month = ds[0], ds[1]
    cur = start_ord
    week_anchor = start_ord - (weekday_of_ordinal(start_ord) - rule.wkst) % 7
    first_period = True

    cache_year = None
    weekinfo = None
    nday_set = None

    while True:
        # Candidate days of this period as (first_ordinal, count).
        if freq == YEARLY:
            first = to_ordinal(year, 1, 1)
            ndays = year_len(year)
        elif freq == MONTHLY:
            first = to_ordinal(year, month, 1)
            ndays = days_in_month(year, month)
        elif freq == WEEKLY:
            first = cur
            ndays = 7 if first_period is False else (rule.wkst - weekday_of_ordinal(cur)) % 7 or 7
            year = from_ordinal(cur)[0]
        else:
            first = cur
            ndays = 1
            year = from_ordinal(cur)[0]
        first_period = False
        # Every occurrence of a period is on or after its first day, so a
        # period starting after UNTIL can produce nothing more.
        if until_key is not None and (first, hh, mm, ss) > until_key:
            return

        # Per-year and per-period precomputation.
        if rule.byweekno is not None and year != cache_year:
            weekinfo = WeekInfo(year, rule.wkst, rule.byweekno)
        if rule.bynday is not None:
            if freq == YEARLY:
                if year != cache_year:
                    nday_set = set()
                    if rule.bymonth is not None:
                        for bm in sorted(rule.bymonth):
                            f = to_ordinal(year, bm, 1)
                            nday_set |= nth_weekday_ordinals(f, f + days_in_month(year, bm) - 1, rule.bynday)
                    else:
                        f = to_ordinal(year, 1, 1)
                        nday_set = nth_weekday_ordinals(f, f + year_len(year) - 1, rule.bynday)
            elif freq == MONTHLY:
                nday_set = nth_weekday_ordinals(first, first + ndays - 1, rule.bynday)
            else:
                nday_set = None
        cache_year = year

        # Walk the candidate days with an incremental date cursor.
        y, m, d = from_ordinal(first)
        yday0 = first - to_ordinal(y, 1, 1)
        ylen = year_len(y)
        dim = days_in_month(y, m)
        wd = weekday_of_ordinal(first)
        selected = []
        o = first
        for _ in range(ndays):
            ok = True
            if rule.bymonth is not None and m not in rule.bymonth:
                ok = False
            elif rule.byweekno is not None and not weekinfo.matches(yday0):
                ok = False
            elif rule.byday is not None and wd not in rule.byday:
                ok = False
            elif nday_set is not None and o not in nday_set:
                ok = False
            elif rule.bymonthday is not None and d not in rule.bymonthday and (d - dim - 1) not in rule.bymonthday:
                ok = False
            elif rule.byyearday is not None and (yday0 + 1) not in rule.byyearday and (yday0 - ylen) not in rule.byyearday:
                ok = False
            if ok:
                selected.append(o)
            # Advance the cursor one day.
            o += 1
            d += 1
            yday0 += 1
            wd = (wd + 1) % 7
            if d > dim:
                d = 1
                m += 1
                if m > 12:
                    m = 1
                    y += 1
                    yday0 = 0
                    ylen = year_len(y)
                dim = days_in_month(y, m)

        if rule.bysetpos is not None:
            chosen = set()
            n = len(selected)
            for p in rule.bysetpos:
                idx = p - 1 if p > 0 else n + p
                if 0 <= idx < n:
                    chosen.add(selected[idx])
            selected = sorted(chosen)

        for o in selected:
            key = (o, hh, mm, ss)
            if until_key is not None and key > until_key:
                return
            if key < dt_key:
                continue
            if remaining is not None:
                remaining -= 1
                if remaining < 0:
                    return
            yy, mo, dd = from_ordinal(o)
            yield (yy, mo, dd, hh, mm, ss)
            emitted += 1
            if emitted >= limit:
                return
            if remaining == 0:
                return

        # Advance to the next period; stop once it would begin after year 9999.
        if freq == YEARLY:
            year += interval
            if year > MAX_YEAR:
                return
        elif freq == MONTHLY:
            month += interval
            year += (month - 1) // 12
            month = (month - 1) % 12 + 1
            if year > MAX_YEAR:
                return
        elif freq == WEEKLY:
            week_anchor += 7 * interval
            cur = week_anchor
            if cur > to_ordinal(MAX_YEAR, 12, 31):
                return
        else:
            cur += interval
            if cur > to_ordinal(MAX_YEAR, 12, 31):
                return


def main():
    data = sys.stdin.read()
    out = []
    for line in data.split('\n'):
        line = line.strip()
        if not line:
            continue
        dt_s, rule_s, n_s = line.split()
        dtstart = parse_dt(dt_s)
        rule = Rule(rule_s, dtstart)
        occ = [fmt_dt(*t) for t in expand(rule, int(n_s))]
        out.append(' '.join(occ))
    sys.stdout.write('\n'.join(out) + ('\n' if out else ''))


if __name__ == '__main__':
    main()
