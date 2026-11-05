# rrule — recurrence rule expansion (RFC 5545 subset)

Each input line gives a start date-time, a recurrence rule (an RFC 5545
`RRULE` value) and a limit `N`. Print the first `N` occurrences of the rule.
Occurrence semantics are those of python-dateutil's `rrule` (which is the
reference behaviour for this problem); the complete algorithm is written out
below so that no knowledge of RFC 5545 or dateutil is needed.

Write the recurrence expansion and the calendar arithmetic (leap years, weekday
of a date, week numbering) yourself: don't use a recurrence-rule, date or
calendar routine from a library, the standard library or the language.

## Input

- UTF-8 (in fact pure ASCII) text on stdin, one rule per line, LF line
  endings (no CR; a final LF may be missing; blank lines do not occur). Up to
  5000 lines (up to 100000 in the long benchmark tier, `bench-long/`).
- Each line is `<DTSTART> <RRULE> <N>` separated by single spaces, with no
  leading or trailing whitespace. Integers are decimal without leading zeros;
  negative values carry a `-` sign and positive values never carry a `+`.
- `DTSTART` is `YYYYMMDDTHHMMSS`: year 1000–9999, a valid calendar date in
  the proleptic Gregorian calendar, hour 00–23, minute and second 00–59. It
  is a floating local time: there are no time zones anywhere in this problem.
- `N` is an integer 1–100000.
- `RRULE` is a `;`-separated list of `NAME=VALUE` parts, upper case, in any
  order, each name at most once, with `FREQ` always present. Values are ASCII
  and never contain spaces. Lists are `,`-separated with no duplicates.

| Part | Value | Notes |
|---|---|---|
| `FREQ` | `YEARLY`, `MONTHLY`, `WEEKLY` or `DAILY` | required |
| `INTERVAL` | integer 1–100 | default 1 |
| `COUNT` | integer 1–100000 | never together with `UNTIL` |
| `UNTIL` | `YYYYMMDDTHHMMSS` | inclusive; may be earlier than `DTSTART` |
| `WKST` | `MO` `TU` `WE` `TH` `FR` `SA` `SU` | week start; default `MO` |
| `BYMONTH` | list of 1–12 | |
| `BYMONTHDAY` | list of 1–31 and −31–−1 | negative counts from the end of the month (−1 = last day) |
| `BYYEARDAY` | list of 1–366 and −366–−1 | only with `FREQ=YEARLY`; negative counts from the end of the year |
| `BYWEEKNO` | list of 1–53 and −53–−1 | only with `FREQ=YEARLY` |
| `BYDAY` | list of weekday codes, each optionally prefixed by a signed ordinal (`MO`, `2MO`, `-1FR`) | see below |
| `BYSETPOS` | list of 1–366 and −366–−1 | |

`BYDAY` restrictions: ordinals (`2MO`, `-1FR`) occur only when `FREQ` is
`MONTHLY` or `YEARLY`, never together with `BYWEEKNO`, and a single `BYDAY`
list is either all plain codes or all ordinal-prefixed codes (never mixed).
The ordinal is 1–5 or −5–−1 when it counts within a month (`FREQ=MONTHLY`,
or `FREQ=YEARLY` with `BYMONTH` present) and 1–53 or −53–−1 when it counts
within a year (`FREQ=YEARLY` without `BYMONTH`). A plain ordinal is written
without a `+` sign.

Inputs are guaranteed to satisfy all of the above; no validation is needed.

## Output

One line per input line, in order: the occurrences as `YYYYMMDDTHHMMSS`
(zero padded, `T` literal) separated by single spaces, in chronological
order, followed by LF. If there are no occurrences the line is empty. Print
nothing else. Exit code 0.

The number of occurrences printed is at most `N`, at most `COUNT`, and only
those not later than `UNTIL`.

## Semantics

Weekdays are numbered MO=0 … SU=6. All dates are in the proleptic Gregorian
calendar (a year is a leap year if it is divisible by 4, except that years
divisible by 100 are leap years only when divisible by 400); as an anchor for
weekday arithmetic, 1 January 2000 is a Saturday and 1 January 0001 is a
Monday. Every occurrence has the time of day of `DTSTART` (hour, minute,
second); only the date varies. Comparisons between
date-times (`>=`, `>`) are chronological.

### 1. Defaults derived from DTSTART

If none of `BYMONTHDAY`, `BYYEARDAY`, `BYWEEKNO`, `BYDAY` is present:

- `FREQ=YEARLY`: if `BYMONTH` is absent, set `BYMONTH` to DTSTART's month;
  in either case set `BYMONTHDAY` to DTSTART's day of month.
- `FREQ=MONTHLY`: set `BYMONTHDAY` to DTSTART's day of month.
- `FREQ=WEEKLY`: set `BYDAY` to DTSTART's weekday (plain, no ordinal).
- `FREQ=DAILY`: nothing.

(So `FREQ=MONTHLY` from a DTSTART on the 31st only produces months that have
31 days, and `FREQ=YEARLY` from 29 February only produces leap years.)

### 2. Periods and candidate days

The rule is evaluated period by period. Each period supplies an ordered list
of candidate days:

- `YEARLY`: period *k* is the calendar year `Y0 + k*INTERVAL` where `Y0` is
  DTSTART's year; candidates are all days of that year, 1 January to 31
  December.
- `MONTHLY`: period *k* is the month obtained by adding `k*INTERVAL` months to
  DTSTART's month (carrying into the year); candidates are all days of that
  month.
- `WEEKLY`: period 0 starts on DTSTART's date and contains that day and the
  following days up to, but not including, the next day whose weekday is
  `WKST` (7 days when DTSTART falls on `WKST`). Let `A` be the most recent
  day on or before DTSTART whose weekday is `WKST`. Period *k* ≥ 1 starts on
  `A + 7*k*INTERVAL` days and contains 7 consecutive days. The candidate days
  of a period may span a month or year boundary.
- `DAILY`: period *k* is the single day `DTSTART date + k*INTERVAL` days.

Periods are enumerated in order. Enumeration stops (the expansion is
finished) when the next period would start in a year later than 9999.
Enumeration may also stop as soon as a period's first day at DTSTART's time
is later than `UNTIL`, since nothing later can be printed; this does not
change the output. `YEARLY`, `MONTHLY` and `DAILY` rules in the tests may run
into the year-9999 limit (a `DAILY` period is a single day, so it never
reaches past 31 December 9999). No `WEEKLY` rule in the tests does: every
`WEEKLY` rule terminates through `COUNT`, `N` or `UNTIL` (its `UNTIL`, when
present, is before year 9950), so no `WEEKLY` period ever contains a day
later than 31 December 9999. An implementation that does not use the `UNTIL`
shortcut may still step a `WEEKLY` or `DAILY` period start past 31 December
9999 while looking for an occurrence later than `UNTIL` in a rule that never
matches; it must be able to do so without failing (dates are plain
integers), and then stops by the rule above.

### 3. Filters

A candidate day is kept only if it passes every filter whose part is present
(after the defaults of step 1). A day's "month day" is its 1-based day of
month, its "negative month day" is `day − (days in that month) − 1` (so the
last day is −1); its "year day" is its 1-based day of year, its "negative
year day" is `yearday − (days in that year) − 1`.

- `BYMONTH`: the day's month is in the list.
- `BYWEEKNO`: see step 4.
- `BYDAY` (plain codes): the day's weekday is in the list.
- `BYDAY` (ordinal codes): the day is one of the days designated by the
  ordinal codes, see step 5.
- `BYMONTHDAY`: the day's month day or its negative month day is in the list.
- `BYYEARDAY`: the day's year day or its negative year day is in the list.

Filters are conjunctive (a day must satisfy all of them); a filter with
several values is satisfied by any one value.

### 4. Week numbering (`BYWEEKNO`)

Weeks start on `WKST` and are 7 consecutive days. Week 1 of calendar year
`Y` is the first week that contains at least four days of `Y`. Let
`first(Y)` be the number of days from 1 January `Y` to the first `WKST`
weekday on or after it (0–6). Week 1 starts on day index `s(Y) = first(Y)`
(0-based from 1 January) if `first(Y) < 4`, and otherwise on
`s(Y) = first(Y) − 7`, i.e. in the previous December. The number of weeks of
`Y` is

    weeks(Y) = floor(L / 7) + (1 if L mod 7 >= 4 else 0),  L = yearlen(Y) − s(Y)

which is always 52 or 53. Each candidate day `d` of the year `Y` currently
being expanded, with 0-based day-of-year index `i`, falls in exactly one
case:

- (a) `s(Y) <= i` and `w = floor((i − s(Y)) / 7) + 1 <= weeks(Y)`: `d` is in
  week `w` of `Y`. It matches if `w` is in `BYWEEKNO` or `w − weeks(Y) − 1`
  is in `BYWEEKNO` (negative values count from the last week: −1 is week
  `weeks(Y)`).
- (b) `i < s(Y)` (the first one to three days of January, which belong to
  the last week of `Y−1`): `d` matches if `−1` is in `BYWEEKNO` or `P` is in
  `BYWEEKNO`, where `P = weeks(Y−1)` if `s(Y−1) < 0`, and otherwise
  `P = 52 + (1 if (yearlen(Y) − s(Y)) mod 7 >= 4 else 0)`.
  `P` is the number python-dateutil assigns to that week and is what this
  problem specifies; for some years (with `WKST=MO`: 1994, 2011, 2022, 2039,
  2050, …) it is 53 even though `Y−1` has only 52 weeks.
- (c) `s(Y) <= i` and `w > weeks(Y)` (the last few days of December, which
  belong to week 1 of `Y+1`): `d` matches if `1` is in `BYWEEKNO`. Negative
  values never match these days.

### 5. Ordinal weekdays (`BYDAY` with ordinals)

An ordinal code `nXX` designates the `n`-th weekday `XX` counted from the
start of a range when `n > 0`, and the `|n|`-th counted backwards from the
end of the range when `n < 0`. The ranges are:

- `FREQ=MONTHLY`: the period's month.
- `FREQ=YEARLY` with `BYMONTH`: each month listed in `BYMONTH`, separately
  (so `BYMONTH=1,7;BYDAY=2MO` designates the second Monday of January and the
  second Monday of July).
- `FREQ=YEARLY` without `BYMONTH`: the whole year.

A designated day that does not exist (a fifth Monday in a month with only
four, `53FR` in a year with 52 Fridays) contributes nothing. The filter keeps
the days designated by at least one code. When `BYMONTH` is also present it
still applies as a filter (step 3), which is a no-op for the months it
selects.

### 6. Selection with `BYSETPOS`

After filtering, if `BYSETPOS` is present, let `C` be the period's list of
kept days in chronological order with `len(C)` elements. For each value `p`,
select `C[p − 1]` if `p > 0` and `C[len(C) + p]` if `p < 0` (0-based
indexing); a `p` whose index is out of range selects nothing. The period's
occurrences are the distinct selected days in chronological order. Without
`BYSETPOS`, the period's occurrences are all kept days. `BYSETPOS` may be
the only `BY…` part written in a rule; it then acts on the days chosen by
the defaults of step 1 (`FREQ=MONTHLY;BYSETPOS=1` from a DTSTART on the 15th
selects the 15th of every month, `BYSETPOS=2` selects nothing). Note that
`BYSETPOS` is applied before the DTSTART check of step 7: with
`FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1` and a DTSTART on the 20th, the first
Monday of DTSTART's month is selected and then discarded, so the first
occurrence is in the next month.

### 7. Emitting

Walk the occurrences of each period in order (periods in order, occurrences
in chronological order within the period), each combined with DTSTART's time
of day:

1. If `UNTIL` is present and the occurrence is later than `UNTIL`: stop the
   whole expansion.
2. If the occurrence is earlier than DTSTART: skip it (it does not count
   towards `COUNT` or `N`).
3. Otherwise print it. Stop after `COUNT` occurrences have been printed, and
   stop after `N` have been printed.

An occurrence equal to DTSTART or equal to `UNTIL` is printed. Because the
candidate days of a period are visited in order and periods do not overlap,
the printed occurrences are strictly increasing.

## Worked examples

Input:

```
19970902T090000 FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=10 100
19970902T090000 FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,TH;COUNT=8 100
19970902T090000 FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=TU,SU;COUNT=4 4
```

Output:

```
19970926T090000 19971128T090000 19980130T090000 19980327T090000 19980529T090000 19980731T090000 19980925T090000 19981127T090000 19990129T090000 19990326T090000
19970902T090000 19970904T090000 19970916T090000 19970918T090000 19970930T090000 19971002T090000 19971014T090000 19971016T090000
19970902T090000 19970907T090000 19970916T090000 19970921T090000
```

The first line is the last Friday of every second month. The second is the
RFC 5545 `WKST` example: with weeks starting on Sunday, 2 September 1997 (a
Tuesday) lies in the week of Sunday 31 August, and period 1 starts two weeks
later on Sunday 14 September, so 16 and 18 September are included. The third
line shows the same rule with `WKST=MO` and `BYDAY=TU,SU`: period 0 is
Tuesday 2 to Sunday 7 September, period 1 starts on Monday 15 September.

Input:

```
20240229T120000 FREQ=YEARLY;COUNT=3 10
20240131T000000 FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20240430T000000 10
20240301T080000 FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3 10
20260101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;COUNT=5 10
```

Output:

```
20240229T120000 20280229T120000 20320229T120000
20240131T000000 20240229T000000 20240331T000000 20240430T000000
20240329T080000 20240430T080000 20240531T080000
```

(The fourth output line is empty, which the listing above cannot show: 30
February never exists, and enumeration stops after year 9999.)

Input:

```
20200101T000000 FREQ=YEARLY;BYWEEKNO=53;BYDAY=MO;COUNT=3 10
20110101T000000 FREQ=YEARLY;BYWEEKNO=53;COUNT=4 10
```

Output:

```
20201228T000000 20261228T000000 20321227T000000
20110101T000000 20110102T000000 20151228T000000 20151229T000000
```

The first line lists the Mondays of week 53 in years that have one (2020,
2026, 2032). The second illustrates case (b) of step 4: Saturday 1 and
Sunday 2 January 2011 precede the start of week 1 of 2011 (Monday 3
January) and get `P = 52 + 1 = 53` because `(365 − 2) mod 7 = 6`, so they
match; 1 January 2012 (a Sunday) gets `P = 52` because `(366 − 1) mod 7 = 1`
and does not match; the next matches are the days of week 53 of 2015,
starting Monday 28 December 2015.

## Performance

The largest tests contain up to 5000 rules per file with small `N`, and
single rules with `N` up to 100000 (e.g. a `DAILY` rule spanning about 270
years). Total output per test is under 5 MB (under 100 MB in `bench-long/`). A straightforward
implementation in a compiled language should complete every test in well
under a second; a suggested per-test timeout is 10 seconds. Rules whose
expansion visits every year up to 9999 before finding nothing (or fewer than
`N` occurrences) occur only with `FREQ=YEARLY`, `FREQ=MONTHLY` and
`FREQ=DAILY`, so at most about 3.3 million candidate days need to be examined
per such rule.
