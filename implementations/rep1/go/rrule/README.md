# rrule

A small Go library and command-line tool that expands RFC 5545 recurrence
rules (`RRULE`) into lists of occurrences, with the semantics of
python-dateutil's `rrule`. Standard library only; all calendar arithmetic
(leap years, weekdays, week numbers) is implemented in the package on integer
day numbers.

Supported: `FREQ` (YEARLY, MONTHLY, WEEKLY, DAILY), `INTERVAL`, `COUNT`,
`UNTIL`, `WKST`, `BYMONTH`, `BYMONTHDAY`, `BYYEARDAY`, `BYWEEKNO`, `BYDAY`
(with ordinals such as `-1FR`) and `BYSETPOS`. Times are floating local times;
there are no time zones. Occurrences never fall after 31 December 9999.

## Build

```
./build.sh          # builds bin/rrule (go build ./cmd/rrule)
go test ./...       # runs the tests
```

Requires Go 1.27 or later.

## Command-line use

`rrule` reads lines `<DTSTART> <RRULE> <N>` from standard input and prints,
for each, the first `N` occurrences, space-separated, one output line per
input line (an empty line when there are none). Timestamps are
`YYYYMMDDTHHMMSS`.

```
$ echo '19970902T090000 FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=4 100' | ./run.sh
19970926T090000 19971128T090000 19980130T090000 19980327T090000
```

Malformed input makes the tool print a message to stderr and exit with
status 1.

## Library use

```go
package main

import (
	"fmt"
	"log"

	"github.com/example/rrule"
)

func main() {
	rule, err := rrule.ParseRule("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3")
	if err != nil {
		log.Fatal(err)
	}
	start, err := rrule.ParseDateTime("20240301T080000")
	if err != nil {
		log.Fatal(err)
	}
	times, err := rule.Expand(start, 0) // 0 = no limit beyond the rule's own
	if err != nil {
		log.Fatal(err)
	}
	for _, t := range times {
		fmt.Println(t) // 20240329T080000, 20240430T080000, 20240531T080000
	}
}
```

`Rule.Each` streams occurrences to a callback instead of building a slice.
`Rule` can also be constructed directly as a struct; `Rule.Validate` checks it.

## Layout

| File | Responsibility |
|---|---|
| `calendar.go` | day numbers, leap years, civil date conversion in O(1) |
| `datetime.go` | `DateTime`, `Weekday`, formatting and parsing |
| `rule.go`, `parse.go` | the `Rule` type, validation, parsing of RRULE text |
| `weekno.go` | `BYWEEKNO` week numbering |
| `expand.go` | period enumeration, filters, `BYSETPOS`, emission |
| `cmd/rrule` | the command-line tool |

## Algorithm

Rules are expanded period by period (year, month, week or day). Each candidate
day of a period is tested in O(1) against lookup tables built from the rule, so
the cost is O(periods + candidate days + occurrences). There are no
rule-specific shortcuts: a rule that never matches is swept through to year
9999.
