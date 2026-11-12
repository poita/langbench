# rrule

Expansion of recurrence rules (an RFC 5545 `RRULE` subset) into concrete
occurrences, with the semantics of python-dateutil's `rrule`. Written in D with
only the standard library; all calendar arithmetic (leap years, weekdays, week
numbers) is implemented here with integer day numbers and closed-form
conversions, so no date/time library is involved.

Supported: `FREQ` (YEARLY, MONTHLY, WEEKLY, DAILY), `INTERVAL`, `COUNT`,
`UNTIL`, `WKST`, `BYMONTH`, `BYMONTHDAY`, `BYYEARDAY`, `BYWEEKNO`, `BYDAY`
(with ordinals), `BYSETPOS`. Date-times are floating (no time zones), years
1000–9999.

Every period (year, month, week or day) is enumerated and each candidate day is
tested against the filters in O(1), so a rule is expanded in time linear in the
number of days examined plus the number of occurrences produced.

## Layout

| Path | Contents |
|---|---|
| `source/rrule/calendar.d` | day numbers, leap years, weekdays |
| `source/rrule/datetime.d` | `LocalDateTime` and the `YYYYMMDDTHHMMSS` format |
| `source/rrule/rule.d` | `Rule` and `parseRule` |
| `source/rrule/weekno.d` | `BYWEEKNO` week numbering |
| `source/rrule/expand.d` | `Occurrences` range and `expand` |
| `source/rrule/query.d` | the `<DTSTART> <RRULE> <N>` line format |
| `source/app.d` | the command-line tool |

## Building

Requires LDC and dub.

```sh
dub build -b release --compiler=ldc2   # or ./build.sh
```

This produces the `rrule` executable in the project directory (`./run.sh`
runs it from anywhere). The library alone: `dub build --compiler=ldc2 -c library`.

Tests (D `unittest` blocks, which also serve as documented examples):

```sh
dub test --compiler=ldc2
```

## Command-line use

The tool reads lines of the form `<DTSTART> <RRULE> <N>` on stdin and writes,
for each line, the first `N` occurrences separated by spaces (an empty line if
there are none).

```
$ printf '19970902T090000 FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=4 100\n' | ./run.sh
19970926T090000 19971128T090000 19980130T090000 19980327T090000
```

* `DTSTART` and `UNTIL` are `YYYYMMDDTHHMMSS`; `N` is 1–100000.
* A line that cannot be parsed produces an empty output line, a message on
  stderr, and exit status 1 at the end; other lines are still processed.

## Library use

```d
import std.stdio;
import rrule;

void main()
{
    auto start = LocalDateTime.parse("19970902T090000");
    auto rule = parseRule("FREQ=MONTHLY;BYDAY=-1FR;COUNT=3");

    // All occurrences as an array (optionally limited)...
    foreach (t; expand(start, rule))
        writeln(t); // 19970926T090000, 19971031T090000, 19971128T090000

    // ...or lazily, as an input range.
    auto occ = new Occurrences(start, parseRule("FREQ=DAILY"));
    writeln(occ.front); // 19970902T090000
    occ.popFront();
}
```

## Notes on semantics

The behaviour follows dateutil, including its quirks: `BYSETPOS` is applied
before the DTSTART check, `FREQ=MONTHLY` from the 31st yields only 31-day
months, and days of early January that precede week 1 are numbered as dateutil
does for `BYWEEKNO`. Enumeration ends after year 9999.
