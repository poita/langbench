# datalog performance benchmark

Regenerate with `python3 gen_bench.py` (fixed seeds; expected outputs from `reference/main.py`, ~95 s total).
Run with `python3 run_tests.py datalog --tests-dir problems/datalog/bench -- <impl>/run.sh`.
All inputs respect SPEC.md limits (<= 10,000 clauses, <= 6 args, <= 60 predicates, <= 8 body literals, <= 3,000 lines per query, < 100 KB output).

- **001_graph_closure_negation** — transitive closure of a 1200-node / 3100-edge random digraph (~1M `path` tuples, mostly one giant SCC) followed by four strata of negation over it (sinks/sources, acyclic nodes, mutual reachability, an all-pairs `not path` anti-join, sink-reachability). This is the textbook Datalog workload: it measures semi-naive linear-recursion throughput, hash-index probes on a large relation and negation lookups, at a scale between the spec's 500-node and 2000-chain tests.
- **002_nonlinear_mutual_recursion** — the algorithmically hardest part of the spec: a doubling closure `link(X,Z) :- link(X,Y), link(Y,Z)` on a 230-node graph, red/blue alternating paths defined by two mutually recursive predicates plus a non-linear `alt :- alt, alt` closure, and same-generation over a 3000-node wide tree. Semi-naive evaluation must handle deltas in every recursive body position; work is dominated by large self-joins rather than I/O, so it rewards good join ordering and indexing.
- **003_points_to_analysis** — a realistic mixed program-analysis workload (the classic Datalog application): Andersen-style points-to for a synthetic 300-function program (allocations, copies, field loads/stores, argument/return flow) with call-graph reachability, dead-function negation, alias pairs via `<`, integer comparisons and a 3-way `callee_sees` join. 8,425 clauses, so parsing and many small relations matter alongside mutually recursive `pt`/`hpt` joins.

Calibration (best of 3, Apple Silicon, impls/*/datalog): 001 cpp 1.94s rust 0.92s go 1.66s d 0.84s python 46s; 002 cpp 2.99s rust 1.95s go 2.56s d 3.14s python 34s; 003 cpp 2.55s rust 0.96s go 1.94s d 1.74s python 22s.
Expected outputs come from the Python reference and are matched exactly by the cpp, rust, go, d and python implementations.

## Long tier

`python3 gen_bench.py --long` writes `../bench-long/` with the same three
programs on larger, denser relations:

- `001`: 1800 nodes and 23,000 edges (was 1200 / 3100), so a nearly complete
  `path` closure (about 3.2M tuples) with the same negation strata.
- `002`: the doubling closure on 290 nodes / 820 edges (was 230 / 650) and the
  red/blue alternating paths on 480 nodes / 1175 edges (was 380 / 930); the
  same-generation tree stays at 3000 nodes.
- `003`: a 1500-function synthetic program (was 300): 42,025 clauses.

Expected outputs come from the reference. It keeps every candidate derivation
of a join in memory, and that is what caps the sizes: each is the largest tried
whose reference run peaks under about 4 GB. Reference runs (peak memory
footprint, user CPU): 001 3.67 GB, 112 s; 002 3.66 GB, 100 s; 003 2.36 GB,
245 s (at 1600 functions it jumps to 4.8 GB).

SPEC.md limits raised for this and still needed: at most 50,000 clauses (was
10,000), at most 5,000 lines per query (was 3,000; 003's `pure_var` query prints
3,268) and total output under 200 KB (was 100 KB; 001 prints 124 KB).

At these sizes the inputs fall below the 5 s target. Fastest canonical build
(user CPU, best of two, loaded machine): 001 3.6 s (D; Go 3.7, Rust 3.9,
C++ 6.3), 002 2.5 s (D; Rust 2.7, Go 2.8, C++ 4.1), 003 4.3 s (D; Go 4.6,
Rust 4.8, C++ 10.7). Peak RSS 200-710 MB. bench-long is about 1.7 MB.
The Python build passes all three in 15 s, 13 s and 21 s of CPU with peak RSS 1.0, 1.3 and 2.1 GB.
