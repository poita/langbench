# ordered-map performance benchmark

Regenerate with `python3 problems/ordered-map/bench/gen_bench.py`. It uses fixed seeds and the `Workload` simulator from `gen_tests.py`, and `check_limits` confirms every input is within SPEC.md. Expected outputs come from `reference/main.py`, which takes 2-3 s per input. The cpp, rust, go, d and python implementations all reproduce them exactly.
SPEC.md caps Q at 200 000 commands and range output at 2 000 000 keys, so each input is as heavy as the spec allows. The compiled implementations still take only about 0.06-0.18 s per input, against about 10-20 ms of process start-up.

- `001_bulk_build_mixed_200k`: bulk-loads 120 000 random 16-digit keys, then runs 80 000 general mixed operations (insert, delete, get, neighbours, rank/select, short ranges). This is ordinary large-map throughput: it measures input parsing, insertion with rebalancing and cache-missing lookups, without leaning on any single degenerate path.
- `002_order_statistics_200k`: builds a map of 90 000 keys, then runs 110 000 operations. About 60% of them are rank, select, floor, ceil, succ and pred, interleaved with about 20% inserts and deletes. This is the algorithmically hardest part of the problem. Size-augmented O(log n) rank/select is required, and the interleaved mutations make the implementation keep subtree counts correct throughout, so precomputed sorted arrays don't help.
- `003_range_scan_heavy_200k`: builds 80 000 keys in [0, 1e6), then runs a phase where half the commands are range queries, averaging about 24 keys each (1.4M keys printed in total, below the 2M cap), mixed with inserts and deletes. It measures in-order traversal and output formatting/buffering (about 10 MB of output), the realistic "scan" workload for an ordered map.

## Long tier

There is no long tier. Every command is an O(log n) operation that the
compiled implementations finish in about 0.3-0.5 µs (measured 0.06-0.11 s user
for 200,000 commands), and range output is bounded by its own cap, so 5-7 s
would need roughly 10-20 million commands per input: about 150-300 MB of input
per case plus output, beyond the on-disk budget. A larger map raises the
per-command cost only modestly (cache misses), not by the 50-100x needed.
