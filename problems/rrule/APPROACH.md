# rrule: required approach

SPEC.md defines what the program does; this note defines how it computes it.
Where the two seem to disagree, SPEC.md wins.

Sizes: for one rule, `P` is the number of periods enumerated, `D` the number of
candidate days examined (at most about 3.3 million) and `K` the number of
occurrences printed.

## Algorithm

Each line is parsed into a rule: the `BY…` parts as sets of values, with the
DTSTART defaults applied. Dates are integer day numbers. The rule is expanded
period by period as SPEC.md §2 describes: each candidate day of the period is
tested against every filter, `BYSETPOS` selects by index among the kept days,
and results are emitted until a limit is reached.

## Required rules

1. **Every period is enumerated and every candidate day of it is tested.** No
   rule-specific shortcuts: no detecting that a rule can never match, no
   jumping to the next period or month that could match, no generating
   candidates directly from `BYMONTHDAY` or `BYYEARDAY`. Enumeration stops only
   at a limit, at the year-9999 bound, or by SPEC.md's `UNTIL` shortcut.
2. **Each candidate day costs O(1).** Values that depend only on the year or
   the range (SPEC.md §4's week numbering, the days of ordinal `BYDAY` codes)
   are computed once for it, not per day.
3. **Date conversions are O(1)**, in closed form (for example via the 400-year
   cycle), with no iteration over years or months.

## Complexity

O(input + Σ(P + D + K)) over all rules: O(1) per period for its setup, O(1) per
candidate day, and O(1) per printed occurrence.
