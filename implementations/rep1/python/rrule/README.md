# rrule

Expands recurrence rules (the `RRULE` subset of RFC 5545) into occurrence
lists, with the same occurrence semantics as python-dateutil's `rrule`.
Pure standard-library Python: the calendar arithmetic (leap years, weekdays,
week numbering) and the expansion are implemented here, not taken from
`datetime`, `calendar` or `dateutil`.

Supported: `FREQ` (YEARLY/MONTHLY/WEEKLY/DAILY), `INTERVAL`, `COUNT`, `UNTIL`,
`WKST`, `BYMONTH`, `BYMONTHDAY`, `BYYEARDAY`, `BYWEEKNO`, `BYDAY` (with
ordinals), `BYSETPOS`. Date-times are floating (no time zones), years 1000–9999.

## Layout

| Module | Responsibility |
|---|---|
| `rrule.dates` | closed-form Gregorian arithmetic on integer day numbers |
| `rrule.rule` | `DateTime`, `Rule`, and the parsers |
| `rrule.expand` | `occurrences()`: period-by-period expansion |
| `rrule.cli` | the stdin/stdout tool |

## Build

Requires Python 3.10+ (developed on 3.14). There is nothing to install:

```sh
./build.sh        # byte-compiles the sources
./run.sh          # runs the CLI (sets PYTHONPATH=src, runs python3 -m rrule)
```

(`pip install .` also works via `pyproject.toml` and provides an `rrule` command.)

## Command line

Input on stdin, one rule per line: `<DTSTART> <RRULE> <N>`, e.g.

```
19970902T090000 FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=10 100
```

For each line the first `N` occurrences (at most `COUNT`, none after `UNTIL`)
are printed as space-separated `YYYYMMDDTHHMMSS` on one line; a rule with no
occurrences gives an empty line.

```sh
echo '20240229T120000 FREQ=YEARLY;COUNT=3 10' | ./run.sh
# 20240229T120000 20280229T120000 20320229T120000
```

## Library

```python
from itertools import islice
from rrule import DateTime, Rule, occurrences

rule = Rule.parse("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1")
start = DateTime.parse("20240301T080000")

for occ in islice(occurrences(start, rule), 3):   # lazy iterator
    print(occ)            # 20240329T080000, 20240430T080000, 20240531T080000

list(occurrences(start, rule, limit=2))           # or pass limit=
```

Public API: `DateTime` (named tuple, `parse`/`isoformat`), `Rule` (`Rule.parse`
or construct directly), `occurrences(dtstart, rule, limit=None)`,
`parse_line`, `RuleError`. Input is assumed to satisfy the restrictions
described in the problem specification; only syntax is checked.

## Tests

```sh
python3 -m pytest
```
