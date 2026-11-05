# rrule

A small D library and command-line tool that expands recurrence rules — the
`RRULE` subset of RFC 5545 (`FREQ` = `YEARLY`/`MONTHLY`/`WEEKLY`/`DAILY`,
`INTERVAL`, `COUNT`, `UNTIL`, `WKST`, `BYMONTH`, `BYMONTHDAY`, `BYYEARDAY`,
`BYWEEKNO`, `BYDAY` with optional ordinals, `BYSETPOS`) — with the occurrence
semantics of python-dateutil's `rrule`.

All calendar arithmetic (leap years, weekdays, week numbers, day-number ⇄ date
conversion) is implemented in the library itself; it depends only on Phobos
and does not use `std.datetime`.

Dates are floating local date-times (no time zones), years 1000–9999 in the
proleptic Gregorian calendar.

## Layout

| Path | Contents |
|---|---|
| `source/rrule/calendar.d` | day numbers, leap years, weekdays, civil dates |
| `source/rrule/timestamp.d` | `YYYYMMDDTHHMMSS` parsing and formatting |
| `source/rrule/rule.d` | the `Rule` record (lookup tables) and `parseRule` |
| `source/rrule/expand.d` | `Expander`, `occurrences` |
| `source/rrule/batch.d` | line-oriented processing used by the CLI |
| `source/rrule/errors.d` | `RRuleException` |
| `source/app.d` | the command-line tool |
| `tests/` | unit tests (separate from the library source) |

## Building

Requires LDC and dub.

```
./build.sh                                   # dub build -b release --compiler=ldc2 --config=cli
dub build -b release --compiler=ldc2 --config=library   # library only
dub test --compiler=ldc2                      # unit tests
```

The executable is written to `bin/rrule`; `run.sh` runs it from any directory.

## Command-line use

`rrule` reads rules from standard input, one per line, and writes one line of
output per rule:

```
<DTSTART> <RRULE> <N>
```

* `DTSTART` — `YYYYMMDDTHHMMSS`
* `RRULE` — e.g. `FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=10`
* `N` — maximum number of occurrences to print (1–100000)

The output line lists the first `N` occurrences (fewer if `COUNT`, `UNTIL` or
the year-9999 limit ends the rule earlier) as space-separated
`YYYYMMDDTHHMMSS` stamps; it is empty if there are none. The tool exits with
status 0, or status 1 with a message on stderr if a line is malformed.

```
$ echo '19970902T090000 FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=4 100' | ./run.sh
19970926T090000 19971128T090000 19980130T090000 19980327T090000
```

## Library use

```d
import std.stdio : writeln;
import rrule;

void main()
{
    auto rule  = parseRule("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3");
    auto start = parseTimestamp("20240301T080000");

    // Convenience API: collect date-times.
    foreach (dt; occurrences(rule, start, 10))
        writeln(formatTimestamp(dt));       // 20240329T080000, 20240430T080000, ...

    // Allocation-free API: reuse an Expander and receive day numbers
    // through any type with `void put(int dayNumber)`.
    Expander expander;
    DayNumberCollector sink;
    expander.expand(rule, start, 10, sink);
    writeln(civilFromDayNumber(sink.days[0]));   // CivilDate(2024, 3, 29)
}
```

## How it works

A date is an integer day number (0001-01-01 is day 0, a Monday), so weekdays
are `n % 7`. A rule is parsed into boolean lookup tables, then expanded period
by period (year, month, week or day); candidate days of each period are walked
with an incremental calendar cursor, filtered with O(1) table lookups, run
through `BYSETPOS`, and emitted. `BYMONTH` skips excluded months wholesale,
week numbering and ordinal weekdays are computed once per year/range, and all
scratch storage is reused across periods and rules.
