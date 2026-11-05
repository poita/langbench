# depresolve performance benchmark

Regenerate with `python3 gen_bench.py` (fixed seeds; expected outputs come
from `reference/main.py`). Run with
`python3 run_tests.py depresolve --tests-dir problems/depresolve/bench -- <impl>/run.sh`.
Every input stays within the size limits in SPEC.md (3 MB, 10,001 lines, 40
requirements per line, 250 versions per package). The search is heavier than
in the test suite, which stays at a few million steps: these inputs take
47 to 72 million search steps (requirements processed, counted with
the reference), so the time goes into the resolver instead of process
start-up. Expected outputs come from the reference (about 3.7 minutes in
total) and match the C++, Rust, Go, D and Python implementations in impls/.

- `001_large_tree_rebuild`: a 2.8 MB, 9,862-line lockfile-style registry
  (480 packages × 20 versions, up to 28 requirements per line) with two
  unconstrained top-level packages (`toolchain`, 200 versions; `runtime`, 60
  versions) and a final `platform` requirement that rejects the newest 149
  toolchains and all but the oldest runtime. The ~420-package tree is built
  and unwound about 9,000 times before the resolution succeeds. This
  measures parsing a large input, plus fast requirement re-checks, choice
  and undo-trail work on a large chosen map: the hot path of a real resolver
  that has to re-resolve after a late conflict.
- `002_random150_sat_backtrack`: a random layered registry (150 packages ×
  10 versions, up to 6 requirements per line, all range forms) that
  backtracks over many millions of steps and then finds a 24-package
  solution. Most of the time goes into filtering candidates against
  caret, tilde and comparator ranges and into chronological backtracking:
  the algorithmically hardest part of the problem, on ordinary ranges.
- `003_random100_unsat_exhaustive`: a random layered registry (100 packages ×
  8 versions, up to 5 requirements per line) with no resolution, so the
  search has to exhaust the whole tree before printing `unsatisfiable`. This
  measures the full cost of failure, with no early exit, and the same mix of
  range checks and backtracking as 002 on a different shape.

## Long tier

`python3 bench/gen_bench.py --long` writes `bench-long/` with the same three shapes and roughly 15-35x the search:

- 001: the same lockfile-style tree (`tree_rebuild`, seed 1101, 480 packages × 20 versions) with 250 toolchain
  versions (the newest 199 rejected) and 1,600 runtime versions, so the tree is rebuilt about 318,000 times instead of
  9,000.
- 002: `random_registry` with the same shape (150 packages × 10 versions, fan 6, 4 root requirements), seed 4011,
  picked by scanning seeds for a satisfiable registry with a long search (23-package solution).
- 003: the same shape as before (100 × 8, fan 5, 4 roots), seed 5041, picked the same way; unsatisfiable.

SPEC.md's limits are raised from 10,001 to 12,001 input lines and from 250 to 1,600 versions of one package (001 needs
both). Expected outputs come from `reference/main.py` (about 1 h for all three) and pass `verify.py`.

Times are user CPU (single run at load average ~10-15 on 8 cores):

| input | fastest (user s) | others (user s) | peak RSS compiled | python (wall / user, RSS) | size |
| --- | --- | --- | --- | --- | --- |
| 001_large_tree_rebuild | cpp 8.6 | go 8.8, d 9.1, rust 9.5 | 30 MB | 285 s / 275 s, 46 MB | 2.9 MB |
| 002_random150_sat_backtrack | rust 6.9 | cpp 7.1, d 7.5, go 8.5 | 4 MB | 413 s / 406 s, 16 MB | 77 KB |
| 003_random100_unsat_exhaustive | cpp 8.9 | rust 9.8, go 11.1, d 11.6 | 4 MB | 650 s / 625 s, 15 MB | 36 KB |

`bench-long/` is 2.9 MB. All five implementations pass all three. The Python implementation needs just over 10 minutes
on 003.
