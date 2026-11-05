# softfloat performance benchmark

Regenerate with `python3 problems/softfloat/bench/gen_bench.py` (fixed seeds 9001-9003).
Expected outputs come from the Python reference (about 1 s per input) and are
cross-checked against the host FPU wherever the spec's special-case rules do not apply.
SPEC.md caps an input at 100,000 lines, so every input is exactly 100,000 lines (about
2 MB). At that cap the compiled implementations finish in 25-50 ms wall time, of which
about 12-19 ms is process start-up. The benchmark is as heavy as the spec allows, but
for compiled languages the compute differences between them are small next to start-up.

- `001_numeric_throughput`: ordinary numeric work. Normal operands, mostly of moderate
  magnitude, plus nearby-exponent pairs that cancel. The mix is add/sub 50%, mul 30%,
  div 10%, sqrt 10%. It measures the common path and I/O parsing and formatting
  throughput, without the special-value shortcuts.
- `002_div_sqrt_heavy`: only div (60%) and sqrt (40%), the most expensive operations
  (long division or restoring square root). It includes denormal operands that must be
  normalised, quotients in the denormal range and some random bit patterns. It measures
  the algorithmically hardest part of the program.
- `003_mixed_realistic`: all five ops, uniformly mixed, across every operand class
  (random bits, normal, moderate, denormal, mixed, special values and NaNs, near-cancelling,
  rounding ties). It is a realistic all-paths workload like the largest public test, but
  with a different seed and more weight on ordinary normal numbers.

## Long tier

There is no long tier. Each line is one independent operation and the compiled
implementations need about 0.1 µs per line, so 5-7 s of work would take about
50-70 million lines (1-1.4 GB of input plus 0.5 GB of expected output), far
beyond a reasonable on-disk size. The format has no way to ask for more work
per byte of input.
