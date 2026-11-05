# orderbook performance benchmark

Regenerate with `python3 problems/orderbook/bench/gen_bench.py` (fixed seeds). Expected outputs come from `reference/main.py`. Run with
`python3 run_tests.py orderbook --tests-dir problems/orderbook/bench -- <impl>/run.sh`.
Every input uses the spec's maximum of 200 000 commands and stays inside its other limits: at most about 45 000 resting orders, at most about 12 000 levels per side, and under 10 MB of output. Because of those limits, the fastest compiled runs take about 0.1–1 s.

- **001_steady_flow_200k**: ordinary continuous trading around a slowly drifting mid, with about 20k resting orders over about 300 levels per side. The mix is passive quotes, marketable limits, IOC/FOK, market orders, cancels and replaces (some keep priority, some lose it), plus about 250 BOOK snapshots. It measures end-to-end throughput: parsing, hash lookups, matching and output formatting (6.7 MB). No single code path dominates.
- **002_deep_ladder_fok_200k**: a deep book with about 44k resting orders over about 9.5k distinct levels per side. About 24% of commands are fill-or-kill blocks whose limits reach 1–3000 ticks (log-uniform) through the opposite best price. Most are rejected, so the cost is checking the liquidity across the crossed levels, not printing trades. The rest of the stream creates levels, cancels orders (which empties levels), replaces orders at new prices, and adds marketable flow at the top of the book. This is the algorithmically hardest part of the spec, and the spec names cross-level FOK sums explicitly. A structure with ordered or aggregate access (D's segment tree) is several times faster than heap pop/push-back scans.
- **003_queue_churn_200k**: a tight market where about 40k orders queue at a few dozen prices, thousands deep per level. Most of the traffic is cancels and replaces aimed at random queue positions, as when market makers re-quote. Aggressive orders eat through the queue fronts and hit many small makers. This stresses removing orders from the middle of a FIFO queue, whether by intrusive unlinking or by lazy deletion with stale-entry skipping, and keeping priority on a quantity decrease.

## Long tier

`python3 bench/gen_bench.py --long` writes `bench-long/` with the same three generators and seeds run for 1,600,000
commands each (8x), with the same book-size limits (resting orders, levels per side). SPEC.md's limits are raised from
200,000 to 2,000,000 commands and from 10 MB to 100 MB of output. Expected outputs come from `reference/main.py`
(about 4 min for all three).

| input | fastest (user s, best of 2) | others (user s) | peak RSS compiled | python (wall / user, RSS) | size |
| --- | --- | --- | --- | --- | --- |
| 001_steady_flow_200k | rust 0.27 | cpp 0.39, d 0.45, go 0.53 | 355 MB (go) | 13 s / 8 s, 823 MB | 77 MB |
| 002_deep_ladder_fok_200k | rust 0.55 | cpp 0.72, d 0.73, go 0.80 | 355 MB (go) | 19 s / 11 s, 847 MB | 81 MB |
| 003_queue_churn_200k | rust 0.21 | cpp 0.27, d 0.37, go 0.41 | 310 MB (go) | 9 s / 5 s, 842 MB | 69 MB |

`bench-long/` is 216 MB. None of the inputs reaches 5 s, and none can within the disk budget: every operation is
O(log P) or O(1) (APPROACH.md), so the work is proportional to the input and output bytes (~45 bytes in plus ~45 bytes
out per command, at 0.15-0.35 µs per command for the fastest build). 6 s would need 20-40 M commands, 2-4 GB per
input. Times were measured on
a heavily loaded machine (user CPU is the closer estimate of an idle run); all five implementations pass all three.
