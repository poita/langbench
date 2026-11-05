# regex performance benchmark

Regenerate with `python3 gen_bench.py` (fixed seeds). Expected outputs come
from `reference/main.py` and are cross-checked line by line against Python's
`re` module (re.ASCII). Run with
`python3 run_tests.py regex --tests-dir problems/regex/bench -- <impl>/run.sh`.

- **001_log_throughput**: 10 typical log-mining patterns (keyword alternations, IP/email/path
  extraction, `\w+`/`\S+` field captures) over 64 long log lines of about 2800-7900 characters (3.4 MB input).
  Most patterns match late or not at all, so the engine tries nearly every start position: this
  measures raw scanning throughput and per-start-position cost on ordinary text, with no
  pathological backtracking.
- **002_backtracking_heavy**: 15 patterns written the way people actually write them (greedy
  `(.*)` captures, anchored CSV/log/access-log/key=value parsers, alternations inside repeated
  groups) over 8100 CSV, log, access-log and key=value records. Greedy runs overshoot and give
  characters back, and failing anchored or unanchored parses enumerate many split points, so this
  stresses the backtracking core, capture save/restore and the choice-point stack. All costs are
  polynomial (no exponential nested quantifiers).
- **003_many_patterns**: the maximum 500 patterns with 200 short subjects each (the maximum
  100000 subjects): 250 realistic validation/extraction patterns over short records plus 250
  random patterns (groups, alternation, classes, counted repeats, anchors) chosen to do a moderate
  amount of backtracking. Measures pattern parsing/compilation, per-subject setup, capture
  bookkeeping and output formatting across many small searches, as in a test-suite or validation
  workload.

Expected outputs are the reference's output (it needs about 11 s, 43 s and 37 s for the three
files); the cpp, rust, go, d and python implementations in impls/ all reproduce them exactly.
Calibration (best of 3, Apple Silicon): cpp 0.46 / 1.07 / 0.92 s, rust 0.41 / 1.00 / 0.97 s,
go 0.63 / 1.82 / 2.24 s, d 0.52 / 1.37 / 2.64 s, python 9.4 / 39 / 56 s.

## Long tier

`python3 bench/gen_bench.py --long [name...]` writes `bench-long/` with the same three workloads and seeds, scaled up:

- 001: the same 10 log-mining patterns over 1,280 long log lines instead of 64 (20x).
- 002: the same 15 patterns with 44x the CSV, log, access-log and key=value records (356,400 subjects).
- 003: 13,000 patterns (26x: half template-based, half random patterns that pass the same backtracking filter), with 200
  short subjects each (2.6 M subjects).

SPEC.md's limits are raised from 500 to 15,000 patterns, from 100,000 to 3,000,000 total subjects and from 4 MB to
200 MB of input (the per-pattern limit of 100,000 subjects is unchanged). Expected outputs come from
`reference/main.py`, cross-checked line by line against Python's `re` (about 45 min for all three).

Times are user CPU, best of 2, at load average ~10-15 on 8 cores:

| input | fastest (user s) | others (user s) | peak RSS compiled | python (wall / user, RSS) | size |
| --- | --- | --- | --- | --- | --- |
| 001_log_throughput | d 1.7 | cpp 1.8, rust 2.2, go 2.6 | 196 MB | 81 s / 78 s, 81 MB | 68 MB |
| 002_backtracking_heavy | cpp 6.8 | rust 7.1, d 7.1, go 9.0 | 227 MB | 501 s / 482 s, 105 MB | 103 MB |
| 003_many_patterns | d 6.1 | rust 6.7, cpp 6.5, go 8.2 | 247 MB | 500 s / 423 s, 101 MB | 115 MB |

`bench-long/` is 273 MB. 001 does not reach 5 s: the input format repeats every subject line for every pattern, and the
scan runs at ~40 MB/s, so 6 s would need ~240 MB for 001 alone. It is kept at 20x so that 002 and 003 fit the disk budget.
All five implementations pass all three.
