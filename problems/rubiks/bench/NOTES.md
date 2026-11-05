# rubiks performance benchmark

Regenerate with `python3 problems/rubiks/bench/gen_bench.py` (fixed seeds). Expected
outputs come from the reference solver (about 5 s per input); verify.py accepts any valid
solution, so the .out files are just one valid answer each.

The spec caps an input at 100 scrambles of at most 1000 moves, and every input here uses
all 100 lines. Within that cap, the compiled implementations' runtime is mostly the one-time
pruning/distance-table build (an empty input takes about as long). Solving 100 scrambles adds
only about 0-40 ms, so these inputs measure start-up plus table build plus solving, and
cannot get much heavier while staying inside the spec.

- 001_random_states_100x25: 100 independent random 25-move scrambles, which are effectively
  uniformly random cube states. This is the throughput workload the spec describes as typical
  (four full phase searches per line).
- 002_long_scrambles_100x1000: 100 scrambles of the maximum 1000 moves (about 260 KB of input).
  It adds the cost of parsing and applying 100k moves to the cost of solving 100 random states,
  and is the largest input the spec allows.
- 003_mixed_patterns_superflip_100: a shuffled realistic mix of 10 named patterns (superflip,
  checkerboard, cube-in-cube, T/U-perm, sexy-move x6), 40 superflip-plus-1..6-random-moves
  states (deep states with every edge flipped, so phase 1 works hardest), 30 random 25-move,
  15 short (1-12 moves), 5 long (100-400 moves) and 2 empty scrambles.

## Long tier

`python3 gen_bench.py --long --solver <compiled run.sh>` writes `../bench-long/` with the
same names (the `100x...` suffixes now describe the short tier only). SPEC.md's scramble
cap is raised from `N <= 100` to `N <= 1000000` for it. The reference solver needs about
40 ms per scramble, far too slow for these sizes, so the expected outputs are the D
implementation's solutions, each accepted by `verify.py` (any valid solution passes;
the .out files are just one valid answer, as for the short tier).

- `001_random_states_100x25`: 900,000 random 25-move scrambles (9,000x), 60 MB in, 77 MB out.
- `002_long_scrambles_100x1000`: 2,000 scrambles of 1000 moves (20x), 5 MB in. Parsing and
  applying the moves costs about as much per byte as reading them, so 5 s would take
  several hundred MB of input; this input is kept small and does **not** reach the
  target (about 0.1 s).
- `003_mixed_patterns_superflip_100`: the same per-100-line mix repeated 9,800 times and
  shuffled (980,000 lines: named patterns, superflip+1..6 moves, random, short, long and
  empty scrambles), 69 MB in, 75 MB out.

Inputs and solutions are about 150 bytes per scramble, so the 300 MB size budget caps
the tier at about 1.9M scrambles in total. Measured on a heavily shared machine (CPU
seconds normalised by a calibration run to a lightly loaded machine): 001 Go 3.9 s
(Rust 6.0, D 8.5, C++ 8.5), 002 Rust 0.1 s, 003 Go 3.7 s (Rust 6.2, D 7.8, C++ 9.7).
So with the Go build, which is much faster than the others here, 001 and 003 also fall
short of 5 s; reaching it would need about 1.5x more scrambles and over 400 MB. Peak RSS
424 MB (Go). Size on disk 273 MB.
