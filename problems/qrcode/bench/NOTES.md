# qrcode performance benchmark

Regenerate with `python3 problems/qrcode/bench/gen_bench.py` (fixed seeds; expected outputs come from `reference/main.py`, about 20 s total).
Run with `python3 run_tests.py qrcode --tests-dir problems/qrcode/bench -- <impl>/run.sh`.
The spec caps an input at 100 queries and version 40, so every input uses the full 100 queries; per-input times are therefore modest (0.1-0.7 s compiled).

- `001_auto_mask_v36_40` — 100 `auto`-mask queries at versions 36-40 (177x177 at most), cycling L/M/Q/H across numeric, alphanumeric, ASCII-byte and UTF-8 payloads.
  It covers the most expensive path: building and penalty-scoring (N1-N4) eight full masked symbols per query. This is the heaviest input the spec allows short of all-v40, without degenerate content.
- `002_fixed_mask_v40_full` — 100 fixed-mask queries (masks 0-7 in rotation), all at version 40 and filled exactly to capacity, across every ECL and mode.
  With no mask search, the time goes to segment encoding, Reed-Solomon over up to 81 blocks, interleaving, function patterns, zigzag placement and output. It isolates the encoder throughput that 001 hides behind the penalty work.
- `003_mixed_realistic` — 100 realistic payloads (URLs with query strings, vCards with UTF-8 names and notes, Wi-Fi strings, alphanumeric tickets, long numeric IDs, UTF-8 text), sizes from a few bytes up to v40, random ECL, 80% `auto`.
  The versions are spread out, so per-query overhead and size-dependent code paths both count, as in a batch QR generator.

## Long tier

`python3 bench/gen_bench.py --long` (from `problems/qrcode/`) writes `bench-long/` with the same three workloads, generators
and seeds, scaled by query count: 001 2,400 queries (24x), 002 3,000 (30x), 003 7,500 (75x). SPEC.md's limit is raised from
100 to 10,000 queries per input. Expected outputs come from `reference/main.py` (about 22 min for all three).

Times are user CPU, best of 2, measured at load average ~10-15 on 8 cores (the machine was never idle). Python times come
from an earlier, more loaded run:

| input | fastest (user s) | others (user s) | peak RSS compiled | python (wall / user, RSS) | size |
| --- | --- | --- | --- | --- | --- |
| 001_auto_mask_v36_40 | cpp 5.4, rust 5.5 | go 10.2, d 10.8 | 268 MB | 352 s / 303 s, 160 MB | 76 MB |
| 002_fixed_mask_v40_full | rust 0.53 | cpp 0.70, d 0.74, go 1.01 | 319 MB | 41 s / 36 s, 206 MB | 105 MB |
| 003_mixed_realistic | cpp 5.4 | rust 5.8, d 9.7, go 10.0 | 288 MB | 446 s / 312 s, 200 MB | 92 MB |

`bench-long/` is 259 MB. 002 does not reach 5 s: every v40 symbol prints 31.5 KB and the fastest encoder needs only
~0.2 ms per query, so 6 s would need ~30,000 queries and ~1 GB of expected output; it is capped by disk instead. All five
implementations pass all three.
