# rrule

A small, dependency-free Rust library and command-line tool that expands
RFC 5545 recurrence rules (`RRULE`) with the occurrence semantics of
python-dateutil's `rrule`. The calendar arithmetic (leap years, weekdays, week
numbers) is implemented in the crate itself; dates are floating local times
with no time zones.

Supported: `FREQ` (`YEARLY`, `MONTHLY`, `WEEKLY`, `DAILY`), `INTERVAL`,
`COUNT`, `UNTIL`, `WKST`, `BYMONTH`, `BYMONTHDAY`, `BYYEARDAY`, `BYWEEKNO`,
`BYDAY` (with ordinals) and `BYSETPOS`. Years 1–9999.

Every period (year, month, week or day) is enumerated and each candidate day is
checked against the filters in O(1), so a rule costs O(periods + candidate
days + occurrences).

## Build

```
./build.sh          # or: cargo build --release
```

The binary is `target/release/rrule`; `./run.sh` runs it from any directory.

## Command-line use

Input on stdin: one request per line, `<DTSTART> <RRULE> <N>`, where `DTSTART`
is `YYYYMMDDTHHMMSS`. Output: one line per request with up to `N` occurrences
(also bounded by `COUNT`/`UNTIL`) in the same format, separated by spaces.

```
$ printf '19970902T090000 FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=3 100\n' | ./run.sh
19970926T090000 19971128T090000 19980130T090000
```

A malformed line makes the tool print a message to stderr and exit non-zero.

## Library use

```rust
use rrule::{DateTime, Recurrence, Rule};

let start: DateTime = "20240131T000000".parse().unwrap();
let rule: Rule = "FREQ=MONTHLY;BYMONTHDAY=-1;COUNT=3".parse().unwrap();
let days: Vec<String> = Recurrence::new(start, &rule).map(|d| d.to_string()).collect();
assert_eq!(days, ["20240131T000000", "20240229T000000", "20240331T000000"]);
```

`Recurrence` is a lazy iterator, so `.take(n)` bounds an otherwise endless
rule. Modules: `calendar` (day-number arithmetic), `datetime`, `rule` (model and
parser), `weeknum` (`BYWEEKNO`), `recurrence` (the engine) and `request` (the
CLI line format).

## Tests

```
cargo test
```

Unit tests live next to the code; `tests/spec_examples.rs` checks the worked
examples through both the library and the binary.
