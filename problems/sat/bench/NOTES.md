# sat performance benchmark

Regenerate with `python3 gen_bench.py` (fixed seeds; the expected outputs come
from the Python reference, about 70 s in total). Run with
`python3 run_tests.py sat --tests-dir problems/sat/bench -- <impl>/run.sh`.
All inputs are within the SPEC.md limits (V <= 2000, C <= 6000, <= 18000
literals, < 128 KB).

- **001_rand3_unsat_225v**: a random 3-SAT instance at the phase transition
  (225 variables, 958 clauses, ratio 4.26), larger than the largest public
  test (200 variables). It is UNSAT, so every solver must finish a complete
  refutation. Run time therefore depends on the core CDCL machinery (propagation,
  first-UIP learning, VSIDS, restarts, learnt-clause management) and not on a
  lucky early model.
- **002_color4_unsat_150v**: 4-colouring a G(n,p) random graph with 150
  vertices and average degree 8.4, just past the colourability threshold (600
  variables, 3802 clauses, mostly binary). This is a structured UNSAT instance
  of the kind found in scheduling and register allocation. It exercises
  binary-clause propagation and learning on symmetric constraints instead of
  random ternary clauses.
- **003_mixed_components_sat**: one satisfiable formula that is close to the
  size limits (1479 variables, 5784 clauses, 15283 literals, 86 KB). It
  combines four near-threshold random 3-SAT instances (n=200, ratio 4.2), a
  planted 3-colouring near its threshold, and an XOR parity chain. Variables
  are permuted and clauses shuffled. It measures parsing, large-formula
  propagation throughput and model output. Solving several independent
  subproblems averages out the heuristic luck that dominates single large
  random SAT instances (single random 3-SAT instances with 1500+ variables
  went from 0.3 s to more than 30 s depending on the seed and solver, so they
  were rejected).

## Long tier

`python3 gen_bench.py --long` writes `bench-long/` (fixed seeds; expected outputs from the Python reference, 21 minutes in total, 110 MB peak RSS). The three instances keep their names and kinds but are much harder:

- **001_rand3_unsat_225v**: random 3-SAT at ratio 4.26 with 275 variables (1172 clauses, seed 6), UNSAT. The name keeps the short tier's "225v"; the instance itself has 275 variables. Single UNSAT instances cannot be split into components (a solver stops at the first refuted component), so the instance size is the lever; seeds were picked so that the instance is UNSAT and takes the compiled solvers several seconds.
- **002_color4_unsat_150v**: 4-colouring of a G(n,p) graph with the same n=150 and average degree 8.4, seed 15 instead of 1 (UNSAT, 3566 clauses). Hardness at this size varies by orders of magnitude between graphs; seed 15 was chosen because all four compiled solvers need 20-30 s on it.
- **003_mixed_components_sat**: 14 copies of the short instance's component mix (56 random 3-SAT n=200 instances with seeds known to be satisfiable, 14 planted 3-colourings, 14 XOR chains), permuted and shuffled together: 20,706 variables, 79,743 clauses, 1.4 MB.

Measured on a heavily loaded 8-core M-series Mac (load average 70-190; CPU time is the reliable figure, wall time was about 2x higher). Fastest per input: 001 D 8.1 s user (16.7 s wall; Go 14.9 s, C++ 19.1 s, Rust 19.2 s); 002 D 22.6 s user (Go 23.7 s, C++ 30.3 s, Rust 31.4 s); 003 Go 12.0 s user (Rust 13.9 s, C++ 14.9 s, D 59.5 s). Peak RSS is at most 260 MB (D on 003). The Python build passes 001 and 003 (about 6 minutes each, under 120 MB) but does not finish 002 within 11 minutes. `bench-long/` is 1.6 MB. SPEC.md's limits sentence now allows `V <= 25000`, `C <= 100000`, 250,000 literal occurrences and 2 MB in the long tier.
