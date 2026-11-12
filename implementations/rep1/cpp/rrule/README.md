# rrule

A small C++17 library and command-line tool that expands RFC 5545 recurrence
rules (`RRULE`) into occurrence lists, following python-dateutil's `rrule`
semantics for the supported subset: `FREQ` = YEARLY / MONTHLY / WEEKLY / DAILY,
`INTERVAL`, `COUNT`, `UNTIL`, `WKST`, `BYMONTH`, `BYMONTHDAY`, `BYYEARDAY`,
`BYWEEKNO`, `BYDAY` (with ordinals) and `BYSETPOS`. Times are floating (no time
zones). All calendar arithmetic (leap years, weekdays, week numbers) is
implemented in the library itself, using only the C++ standard library.

## Layout

| Path | Contents |
|---|---|
| `include/rrule/date.hpp`, `src/date.cpp` | Proleptic Gregorian calendar: O(1) date <-> day-number conversion, weekdays, formatting |
| `include/rrule/rule.hpp`, `src/rule.cpp` | `Rule` data model and DTSTART-derived defaults |
| `include/rrule/parser.hpp`, `src/parser.cpp` | Parsing of `YYYYMMDDTHHMMSS` and `RRULE` text |
| `include/rrule/expander.hpp`, `src/expander.cpp` | Period-by-period expansion |
| `include/rrule/rrule.hpp` | Umbrella header |
| `cli/main.cpp` | The `rrule` command-line tool |
| `tests/` | GoogleTest unit tests |

## Build

Requires CMake >= 3.20 and a C++17 compiler. GoogleTest is optional (tests are
skipped when it is not found; `-DRRULE_BUILD_TESTS=OFF` disables them).

```sh
./build.sh            # Release build into ./build
ctest --test-dir build   # run the unit tests
```

## Command-line use

`./run.sh` (or `build/rrule`) reads lines of the form
`<DTSTART> <RRULE> <N>` on stdin and prints, for each line, the first `N`
occurrences separated by spaces:

```
$ printf '19970902T090000 FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=3 100\n' | ./run.sh
19970926T090000 19971128T090000 19980130T090000
```

`DTSTART` and the output use `YYYYMMDDTHHMMSS`. A rule with no occurrences
yields an empty line. A malformed line yields an empty line and a message on
stderr; the exit code is 0.

## Library example

```cpp
#include <iostream>
#include "rrule/rrule.hpp"

int main() {
  rrule::DateTime start = rrule::parse_datetime("20240131T090000");
  rrule::Rule rule = rrule::parse_rule("FREQ=MONTHLY;BYMONTHDAY=-1");
  for (const rrule::DateTime& t : rrule::expand(start, rule, 5))
    std::cout << rrule::format_datetime(t) << '\n';
}
```

Link against the `rrule::rrule` CMake target (`add_subdirectory` this project).

## How expansion works

Each period (year, month, week or day) is enumerated; every candidate day in it
is tested in O(1) against the filters (per-year week numbering and per-range
ordinal weekdays are computed once per period); `BYSETPOS` then selects among
the kept days; occurrences before DTSTART are dropped, and expansion stops at
`COUNT`, the limit, `UNTIL`, or the year-9999 bound. No rule-specific shortcuts
are taken, so cost is O(periods + candidate days + occurrences).
