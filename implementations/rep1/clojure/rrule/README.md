# rrule

A small, dependency-free Clojure library and command-line tool that expands
RFC 5545 recurrence rules (`FREQ` = `YEARLY`, `MONTHLY`, `WEEKLY`, `DAILY`
with `INTERVAL`, `COUNT`, `UNTIL`, `WKST`, `BYMONTH`, `BYMONTHDAY`,
`BYYEARDAY`, `BYWEEKNO`, `BYDAY`, `BYSETPOS`) into occurrences, with the
semantics of python-dateutil's `rrule`. Date-times are floating (no time
zones).

All calendar arithmetic (leap years, weekdays, week numbers, day-number
conversion in closed form) is implemented in the library itself; it uses no
JVM date/time classes.

Each period (year, month, week or day) is enumerated and every candidate day
is tested against the filters in O(1), so a rule costs
O(periods + candidate days + occurrences).

## Layout

| Namespace          | Responsibility                                              |
|--------------------|-------------------------------------------------------------|
| `rrule.core`       | public API                                                  |
| `rrule.calendar`   | day numbers, weekdays, leap years, week numbering           |
| `rrule.datetime`   | parsing / formatting of `YYYYMMDDTHHMMSS`, timestamps       |
| `rrule.parse`      | RRULE and input-line parsing                                |
| `rrule.rule`       | defaults a rule derives from its DTSTART                    |
| `rrule.expand`     | the period-by-period expansion engine                       |
| `rrule.cli`        | command-line front end                                      |

## Build

Requires Java and the `clojure` CLI (tested with Clojure 1.12.6, Java 27).

    ./build.sh

AOT-compiles the CLI into `target/classes` and records the classpath so that
`run.sh` starts quickly. (`run.sh` also works without building, just slower.)

## Command line

`run.sh` reads lines of the form `<DTSTART> <RRULE> <N>` on stdin and prints,
for each, the first `N` occurrences as `YYYYMMDDTHHMMSS` separated by single
spaces (an empty line if there are none):

    $ echo '19970902T090000 FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=4 100' | ./run.sh
    19970926T090000 19971128T090000 19980130T090000 19980327T090000

Malformed input makes the tool print a message on stderr and exit with
status 1.

## Library

```clojure
(require '[rrule.core :as rrule])

;; strings in, strings out
(rrule/occurrence-strings "20240229T120000" "FREQ=YEARLY" {:limit 3})
;=> ["20240229T120000" "20280229T120000" "20320229T120000"]

;; datetime maps
(rrule/occurrences "19970902T090000" "FREQ=WEEKLY;BYDAY=TU,TH;COUNT=2")
;=> [{:year 1997 :month 9 :day 2 :hour 9 :minute 0 :second 0}
;    {:year 1997 :month 9 :day 4 :hour 9 :minute 0 :second 0}]

;; pre-parsed rules
(def r (rrule/parse-rule "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"))
(rrule/occurrence-strings "20240301T080000" r {:limit 3})
;=> ["20240329T080000" "20240430T080000" "20240531T080000"]
```

Public functions in `rrule.core`: `parse-rule`, `timestamps`, `occurrences`,
`occurrence-strings`, `expand-line`. Expansion stops at `COUNT`, `UNTIL`, the
`:limit` option, or the end of year 9999, whichever comes first.

## Tests

    clojure -M:test

Runs the unit and `test.check` property tests with the Cognitect test-runner.
