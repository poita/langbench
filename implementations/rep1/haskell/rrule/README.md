# rrule

A small Haskell library and command-line tool that expands RFC 5545
recurrence rules (`RRULE`) into occurrences, with the semantics of
python-dateutil's `rrule`.

Supported: `FREQ` = `YEARLY`, `MONTHLY`, `WEEKLY`, `DAILY`, with `INTERVAL`,
`COUNT`, `UNTIL`, `WKST`, `BYMONTH`, `BYMONTHDAY`, `BYYEARDAY`, `BYWEEKNO`,
`BYDAY` (with ordinals such as `-1FR`) and `BYSETPOS`. Dates are floating
(time-zone free) date-times in the proleptic Gregorian calendar, years
1000–9999. All calendar arithmetic (leap years, weekdays, week numbers) is
implemented in the library; it depends only on `base`, `array`, `containers`
and `bytestring`.

Expansion enumerates every period (year, month, week or day) and tests every
candidate day against each filter in constant time, so the cost is linear in
the number of days examined; there are no rule-specific shortcuts.

## Build

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh          # builds and copies the tool to bin/rrule
cabal test          # runs the hspec/QuickCheck test suite
```

## Command-line use

`rrule` (or `./run.sh`) reads lines of the form `<DTSTART> <RRULE> <N>` on
stdin and writes, for each, up to `N` occurrences on one line, separated by
spaces and formatted `YYYYMMDDTHHMMSS`. A rule with no occurrences gives an
empty line.

```console
$ printf '%s\n' \
    '19970902T090000 FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=4 100' \
    '20240229T120000 FREQ=YEARLY 3' | ./run.sh
19970926T090000 19971128T090000 19980130T090000 19980327T090000
20240229T120000 20280229T120000 20320229T120000
```

Malformed input makes the tool print a message on stderr and exit non-zero.

## Library use

```haskell
import RRule

main :: IO ()
main = do
  let Right start = parseDateTime "19970902T090000"
      Right rule  = parseRule "FREQ=MONTHLY;BYDAY=-1FR;COUNT=3"
  mapM_ (putStrLn . formatDateTime) (occurrences start rule)
  -- 19970926T090000
  -- 19971031T090000
  -- 19971128T090000
```

`occurrences :: DateTime -> Rule -> [DateTime]` is lazy and ordered; it ends at
the rule's `COUNT`/`UNTIL` or the end of year 9999, so use `take` to bound
open-ended rules. Rules can also be built directly from `defaultRule` and the
`Rule` record fields.

## Modules

| Module | Responsibility |
|---|---|
| `RRule` | convenient re-exports |
| `RRule.Types` | `Rule`, `DateTime`, `Frequency`, `Weekday`, `ByDay` |
| `RRule.Parse` | parse `RRULE` values and date-times |
| `RRule.Expand` | the expansion algorithm |
| `RRule.Calendar` | closed-form calendar arithmetic on day numbers, week numbering |
| `RRule.Format` | render date-times |
| `RRule.Batch` | the line format used by the CLI |

Rules are not validated against the RFC 5545 cross-part restrictions
(e.g. `BYYEARDAY` with `FREQ=MONTHLY`); behaviour for such rules is unspecified.
