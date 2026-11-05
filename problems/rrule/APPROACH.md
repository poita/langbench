# rrule — required approach

SPEC.md defines what the program does. This note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

Read all of standard input with one bulk read, parse each line by hand into a
compact rule record whose `BY…` parts are fixed-size boolean lookup tables,
apply the DTSTART defaults, and expand the rule period by period exactly as
SPEC.md describes. Dates are plain integer day numbers. For each period the
program walks its candidate days with an incremental calendar cursor, tests
every filter with O(1) table lookups against per-year or per-period data
computed once, collects the kept day numbers in a reused buffer, applies
`BYSETPOS` by index, and emits occurrences as hand-formatted 15-byte stamps
into one output buffer that is written once at the end.

Sizes below: `R` is the number of rules, `P` the number of periods a rule
enumerates, `D` the number of candidate days it examines (at most about 3.3
million per rule, SPEC "Performance"), `K` the number of occurrences printed.

## Required choices

1. **Input, O(input size).** One bulk read of stdin. Split lines and fields
   by scanning bytes; parse `YYYYMMDDTHHMMSS` and integers with manual digit
   loops on fixed offsets. No regular expressions, no general-purpose
   date parsing, no per-field string copies where the language has cheap
   slices.
2. **Date representation.** A date is one integer day number (day 0 or 1 =
   0001-01-01, a Monday), so the weekday is `(n + c) mod 7` for a fixed
   constant `c` with no table lookup. Convert civil date to day number with the closed form
   (`365·(y−1) + (y−1)/4 − (y−1)/100 + (y−1)/400` + cumulative month days +
   day). Convert a day number back to a civil date only with an O(1)
   closed-form (400-year era) formula. A date-time compares as the pair
   (day number, seconds of day) or one combined integer; DTSTART and UNTIL
   are converted once per rule.
3. **Rule record with lookup tables.** Each list part becomes a boolean table
   indexed by value, with separate tables for positive and negative values:
   months `[1..12]`, month days `±[1..31]`, year days `±[1..366]`, week numbers
   `±[1..53]`, plain weekdays `[0..6]`. Every filter test is one or two array
   reads: `pos[d] || neg[len+1−d]`. Ordinal `BYDAY` codes and `BYSETPOS`
   values stay as short lists of (ordinal, weekday) pairs and integers.
   `COUNT` and `N` are combined into one limit.
4. **Period enumeration, O(P).** Compute each period's start day number and
   length directly from the period index or from the previous period:
   YEARLY by year arithmetic, MONTHLY by a running month index
   (`12·year + month − 1 + k·INTERVAL`), WEEKLY from the WKST anchor `A` plus
   `7·k·INTERVAL`, DAILY as start `+ k·INTERVAL`. Stop at the year-9999 limit
   (YEARLY/MONTHLY by the period's year; WEEKLY/DAILY by comparing the start
   day number with the precomputed day number of 10000-01-01, with no date
   conversion) and, before doing any work on a period, stop when the
   period's first day at DTSTART's time is later than UNTIL (the shortcut
   SPEC permits). Every period up to that point is enumerated and walked:
   no period is skipped except as item 6 requires.
5. **Candidate walk with an incremental cursor, O(D).** Derive (year, month,
   day of month, 0-based day of year, weekday, month length, year length)
   once for the period's first day, then advance them by increment and
   rollover per day. Never call a full day-number-to-date conversion, a
   leap-year test or a month-length computation per candidate day beyond
   what the rollover needs. For DAILY and WEEKLY, the per-period setup is the
   dominant cost on long sweeps: derive the start's civil fields either by
   carrying the cursor forward from the previous period or with the O(1)
   closed-form conversion, never by looping over months or years.
6. **Skip months excluded by `BYMONTH` wholesale.** For YEARLY periods iterate
   only the months whose `BYMONTH` entry is set (all twelve when absent),
   starting each at its cumulative day offset; for MONTHLY periods whose
   month is excluded, produce nothing without walking its days. A rule like
   `BYMONTH=2;…` then examines 28–29 days per year, not 365.
7. **Week numbering once per year, O(1) per day.** When `BYWEEKNO` is present,
   compute `s(Y)`, `weeks(Y)` and the week number `P` of SPEC step 4 once per
   period year (YEARLY periods each have one year), either keeping these
   three integers and classifying each day with one division by 7, or filling
   a per-year boolean mask of the year's days. Use exactly the three cases of
   SPEC step 4, including the special value `P`.
8. **Ordinal weekdays by direct computation, O(codes · ranges) per period.**
   For each range (the month, each `BYMONTH` month, or the whole year) and
   each code `nXX`, compute the designated day arithmetically: the first `XX`
   on or after the range start plus `7·(n−1)`, or the last `XX` on or before
   the range end minus `7·(|n|−1)`, discarding it if it falls outside the
   range. Mark the results in a period-sized boolean mask (clearing only the
   period's length) or a small sorted list; the per-day test is then O(1) or
   a short search. For YEARLY rules this is computed once per year.
9. **Kept days and `BYSETPOS`, O(kept) per period.** Append kept day numbers
   (or day offsets within the period) to one reusable buffer cleared per
   period. With `BYSETPOS`, map each value to an index into that buffer,
   discard out-of-range ones, and produce the distinct selected days in
   chronological order (sort and deduplicate the at most `|BYSETPOS|`
   indices, or mark them in a reusable flag array).
10. **Emitting, O(K).** For each occurrence: compare with UNTIL (stop all),
    compare with DTSTART (skip), then convert the day number to a civil date
    once and write the 15 stamp bytes digit by digit into the shared output
    buffer, with a space separator and `\n` per rule. Stop as soon as the
    combined limit is reached. The whole output (at most 5 MB) is written
    with one write at the end, or through one large buffered writer.
11. **Overall cost.** O(input + Σ(P + D + K)) time; memory O(366) working
    space per rule plus the input and output buffers. No allocation inside
    the period or day loops: all scratch buffers (kept days, selection,
    ordinal mask, week mask) are allocated once and reused across periods
    and rules.

## Left to the implementer

- Container types, struct layout, naming, module structure, and the epoch of
  the day number.
- Whether week numbering uses the three per-year integers or a per-year mask,
  and whether ordinal designations are a mask or a sorted list.
- The order in which filters are tested inside the day loop (they are
  conjunctive; any order gives the same result).
- Whether kept entries are absolute day numbers or offsets within the period.
- Whether the DAILY/WEEKLY start date comes from a carried cursor or from the
  closed-form conversion, provided it is O(1) per period without loops.
- Loop-level micro-optimisations: integer widths, specialised loops per
  frequency, bounds-check elimination, branch ordering.
- How UNTIL is compared: as a (day, seconds) pair, or as one precomputed
  last printable day number (the time of day is the same for every
  occurrence).

## Pitfalls

- Converting each candidate day (or each DAILY/WEEKLY period start) from a
  day number to a civil date with a loop over months, or calling the full
  conversion twice per period (once for the year-9999 check and once for the
  walk). On the year-9999 DAILY sweeps this per-period overhead dominates.
- Walking all 365 days of a YEARLY period and rejecting most of them by the
  `BYMONTH` test, instead of iterating only the selected months.
- Testing list membership with a linear search, a hash set or a tree set per
  candidate day instead of indexing a boolean table; for negative values,
  forgetting to precompute the negative table and building `d − len − 1`
  lookups through a general map.
- Recomputing week-numbering data (`s(Y)`, `weeks(Y)`, `s(Y−1)`, `P`) per
  candidate day, or recomputing the ordinal designations per day by counting
  weekdays from the start of the range.
- Allocating a fresh kept-days list, ordinal mask, selection set or range
  list for every period, or clearing a full 366-entry mask when the period
  has 1 or 7 days.
- Producing occurrences as date objects or tuples and formatting them
  through a general-purpose formatter (`printf`-style or string
  interpolation), joining per-rule string lists, or writing each occurrence
  with an unbuffered or flushed write.
- Rule-specific shortcuts beyond item 6: recognising that a rule can never
  match (for example `BYMONTH=2;BYMONTHDAY=30`) and stopping early, jumping
  DAILY or MONTHLY periods straight to the next selected month, skipping
  non-leap years, or generating candidate days directly from `BYMONTHDAY`
  or `BYYEARDAY` instead of walking the period. These change the
  algorithmic work of the sweep rules and are not allowed.
- Building per-rule output by repeated string concatenation in a language
  where that copies the whole string.
- Reading input line by line through an unbuffered stream, or splitting the
  rule with general-purpose split functions that allocate a string per part
  and per list item, in the hot path of 5000-rule inputs.
