# rrule

`rrule` expands iCalendar (RFC 5545) recurrence rules into occurrences, with
the semantics of python-dateutil's `rrule`. It is a dependency-free Go library
plus a small command-line filter.

Supported: `FREQ` (`YEARLY`, `MONTHLY`, `WEEKLY`, `DAILY`), `INTERVAL`,
`COUNT`, `UNTIL`, `WKST`, `BYMONTH`, `BYMONTHDAY`, `BYYEARDAY`, `BYWEEKNO`,
`BYDAY` (with ordinals such as `2MO`, `-1FR`) and `BYSETPOS`. Times are
floating local times (no time zones); years 1000–9999. The calendar
arithmetic is implemented in the package itself; only the Go standard library
is used, and not even its `time` package.

## Build

Requires Go 1.27 or newer.

```sh
./build.sh          # writes bin/rrule
go test ./...       # unit tests
```

## Command-line use

`bin/rrule` (or `./run.sh`) reads lines of `<DTSTART> <RRULE> <N>` from stdin
and prints, per line, up to `N` occurrences separated by spaces (an empty
line when there are none):

```console
$ printf '19970902T090000 FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=4 100\n' | ./run.sh
19970926T090000 19971128T090000 19980130T090000 19980327T090000
```

`DTSTART` and `UNTIL` are written `YYYYMMDDTHHMMSS`. A malformed line makes
the tool print the output produced so far, report the problem on stderr and
exit with status 1.

## Library use

```go
package main

import (
	"fmt"

	"github.com/example/rrule"
)

func main() {
	r, err := rrule.ParseRule("FREQ=MONTHLY;BYDAY=-1FR;COUNT=3")
	if err != nil {
		panic(err)
	}
	start, _ := rrule.ParseDateTime("19970902T090000")
	times, _ := r.Expand(start, 100) // at most 100, and never more than COUNT
	for _, t := range times {
		fmt.Println(t) // 19970926T090000, 19971031T090000, 19971128T090000
	}
}
```

For many rules, reuse an `rrule.Expander`: it keeps its scratch buffers
between calls, and `AppendText` writes the stamps straight into a byte slice
without allocating per occurrence. `Each` streams occurrences to a callback
that can stop the expansion early.

## Layout

| File | Responsibility |
|---|---|
| `date.go` | leap years, day numbers, closed-form date conversion, weekdays |
| `datetime.go` | the `DateTime` type, parsing and formatting |
| `rule.go`, `parse.go` | the `Rule` type, `ParseRule`, validation |
| `compile.go` | lowering a rule to lookup tables and applying DTSTART defaults |
| `weekno.go`, `ordinal.go` | `BYWEEKNO` numbering and ordinal `BYDAY` designation |
| `expand.go` | period enumeration, candidate walk, `BYSETPOS`, emission |
| `cmd/rrule` | the command-line tool |

## Algorithm

Dates are integer day numbers (day 0 = 0001-01-01, a Monday). A rule is
evaluated period by period; each period's candidate days are walked with an
incremental calendar cursor and tested against boolean lookup tables, the
kept days are reduced by `BYSETPOS`, and occurrences earlier than `DTSTART`
are skipped. Expansion stops at `COUNT`/limit, after `UNTIL`, or at the end of
year 9999.
