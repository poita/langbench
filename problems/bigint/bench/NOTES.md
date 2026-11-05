# bigint performance benchmark

Regenerate with `python3 problems/bigint/bench/gen_bench.py` (fixed seeds; expected outputs come from `reference/main.py`, about 10 s in total). Run with `python3 run_tests.py bigint --tests-dir problems/bigint/bench -- <impl>/run.sh`. All inputs stay within the SPEC limits: at most 10,000 queries and 8 MB, operands of at most 50,000 digits, results of at most 100,000 digits.

- `001_mul_large` has 72 signed multiplications: 6 square 45k-50k digit products, 10 at 25k-35k digits, 16 unbalanced products (45k by 2k-8k digits) and 40 at 5k-15k digits. It measures the multiplication kernel at the sizes the spec names as the largest, across square and lopsided shapes, so no single fast path decides the result.
- `002_divmod_large` has 80 `/` and `%` queries with 30k-50k digit dividends. The divisors are balanced (about 25k digits), medium (5k-12k), nearly as long as the dividend (35k-39k, so the quotient is short), 1-18 digits (single- or double-limb), or built as q*d + r with zero runs in the quotient. Long division is the hardest part of the program, and this mix covers normalisation, trial-digit correction and the small-divisor path.
- `003_mixed_workload` has 1,714 queries with every operation. The mix is roughly 30% `+`/`-`, 25% `*`, 20% `/`/`%`, 7% `^` (results up to about 99k digits) and 18% `cmp`, plus a few error cases. Operand sizes are log-uniform from 1 to 12,000 digits, and the input is 4 MB. It is a realistic calculator stream that also exercises parsing, decimal output (5.4 MB) and exponentiation.

## Long tier

`python3 bench/gen_bench.py --long` writes `bench-long/` (fixed seeds 17001-17003; expected outputs from `reference/main.py`, about 80 s in total, 210 MB peak RSS). Each input keeps the short input's query mix and operand-size distribution and only adds queries, so per-query operand and result sizes stay inside the limits above:

- `001_mul_large`: the 72-product block repeated 9 times with fresh operands (648 products, 25 MB in, 25 MB out).
- `002_divmod_large`: the 80-query division block repeated 7 times (560 queries, 34 MB in, 11 MB out).
- `003_mixed_workload`: the same calculator stream continued to 20 MB (9,273 queries, 29 MB out).

Measured on a heavily loaded 8-core M-series Mac (CPU time is the reliable figure; wall time was 1.2-2.5x higher): the fastest build is Go on 001 (8.5 s user, 10.0 s wall), C++ on 002 (8.4 s user; Go 8.9 s user, 11.1 s wall) and Go on 003 (8.7 s user, 11.4 s wall). Rust takes 8.6-13 s user, D 9.8-15.4 s. Peak RSS is at most 140 MB (Go). The Python build takes 85-137 s on the short inputs, so it needs well over 10 minutes on each long input. `bench-long/` is 138 MB on disk. SPEC.md's 8 MB input cap was raised to 40 MB for the long tier only (`bench-long/`); the 10,000-query, operand and result limits are unchanged.
