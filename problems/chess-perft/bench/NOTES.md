# chess-perft performance benchmark

Regenerate with `python3 problems/chess-perft/bench/gen_bench.py` (fixed seeds, about 5 minutes).
Positions come from seeded random games played with the reference generator. Queries are added in a fixed order until each file holds about 19 million leaf nodes, which is as heavy as SPEC.md allows (it caps a file at about 20M leaves and 160 queries). Expected outputs are produced by the Python reference's own query logic. cpp, rust, go, d and python all match them.

- `001_middlegame_d4`: 8 `perft 4` queries on busy opening and middlegame positions (20 or more pieces, taken from random games starting at the standard and published perft positions), 19.4M leaves. This is plain move-generation throughput on wide trees with 30 to 50 moves per node, where bulk counting at the leaves is most effective. It is the workload perft is usually benchmarked on.
- `002_endgame_deep`: 13 queries on endgames with 4 to 11 pieces at depth 6 (depth 5 for the larger ones), 19.3M leaves. The branching factor is low, so there are many more interior nodes per leaf. That puts the weight on make/unmake, check and pin detection, king-move legality and promotions rather than on counting leaves.
- `003_mixed_divide_160`: 160 queries, the most the spec allows, on positions from every game phase. Depths run from 1 to 5, about half the queries are `divide`, and the file totals 18.7M leaves with about 1000 output lines. It is a realistic mix: per-query FEN parsing and setup, sorted divide output, and searches from shallow to deep.

## Long tier

`python3 bench/gen_bench.py --long` writes `bench-long/` with the same three workloads at about 30-100 times the leaf count (new seeds 1101/1202/1303; candidates are accepted on an extrapolated leaf estimate, so only accepted queries are searched in full):

- `001_middlegame_d4`: 791 `perft 4` queries on busy middlegame positions, about 2.0 billion leaves (100x).
- `002_endgame_deep`: 36 endgame queries at depth 7 (positions with up to 8 pieces) or 6, about 550 million leaves.
- `003_mixed_divide_160`: still exactly 160 queries, half of them `divide`, but with the depth cycle shifted up by one (2-6), about 1.8 billion leaves.

All three expected outputs come from the Python reference: about 2 h 15 min of CPU for 001 and 002 together and 32 min for 003 (1,944 s user, 2,055 s wall, 17 MB peak RSS), on a loaded machine. The C++, Rust, Go and D builds reproduce all three byte for byte.

Measured on a heavily loaded 8-core M-series Mac (load average 70-190), so CPU (user) time is the reliable figure and wall time was 1.3-2x higher: fastest is C++ on 001 (7.7 s user, 15.7 s wall) and 002 (6.7 s user, 10.2 s wall), and D on 003 (11.9 s user; C++ 12.0 s). Go and Rust take 9-17 s user. Peak RSS is under 10 MB for every compiled build. `bench-long/` is 0.1 MB. The Python build needs about 100x the leaf rate of the compiled ones (13-18 s on each short input), so it takes far longer than 10 minutes on every long input.

SPEC.md's Performance section now states the long-tier sizes (up to 1000 queries, about 200 million leaves per query, about 2 billion per file, depth 7 with up to eight pieces).
