# jq performance benchmark

All three inputs share one full-size document: 28,500 generated employee records
(`gen_tests.gen_records(101, 28500)`, 5.75 MB compact, under the 6 MB limit), so
every run pays the same JSON parse cost and the differences come from the filters.
Expected outputs come from `reference/main.py` (about 45 s for all three) and are
cross-checked byte for byte against jq 1.7.1. Regenerate them with `python3 gen_bench.py`.

- `001_large_record_stream`: an ETL-style `.[] | select(...) | {...}` that reshapes
  24,212 records into enriched objects (manager lookup through a `$all` binding, a
  tag sort plus a reduce, if/elif bands, string split and concat) and prints about 7 MB.
  It measures end-to-end parse, evaluate and print throughput on an ordinary large job.
- `002_sort_group_records`: report sections built from `sort`, `unique`, `min`/`max` of
  whole records, `sort_by` and `group_by` with composite and array keys, and `unique` on
  objects and arrays. It stresses the total-order comparator (key-list and value comparison
  of objects) and stable sorting of 28.5k elements, the most algorithmically demanding
  part of the language.
- `003_join_reduce_mixed`: an interpreter-bound mix. It runs a nested-generator self-join
  over a 2,000-record slice (4M inner evaluations with variable bindings), `reduce` with
  object accumulators (`+` and the recursive `*`), a per-record reduce over tags, and
  `tostring`/split/`tonumber` round trips. This exercises the core evaluator, environments
  and the cost of immutable value updates.

## Long tier

`python3 gen_bench.py --long` writes `../bench-long/` (same names, same document,
expected outputs from `reference/main.py`, cross-checked against jq 1.7.1; about 35
minutes). The document stays at the 6 MB limit (28,500 records); each filter repeats
its work over it instead, so the inputs stay 5.75 MB each (23 MB in total with outputs).
The jq subset has no `range`, so pass counters iterate a literal array.

- `001_large_record_stream`: 64 passes over `.[]`; every pass reshapes every selected
  record (manager lookup, tag sort and reduce, bands, string split) and emits only the
  records with `.id % 64 == pass`, so the output is the same 24,212 objects (7 MB) in
  a different order, after 64x the evaluation work.
- `002_sort_group_records`: the whole report runs 24 times, once per leave-one-fold-out
  subset (`map(select(.id % 24 != fold))`), so every sort, `group_by`, `unique` and
  `min`/`max` runs over about 27.3k records 24 times.
- `003_join_reduce_mixed`: the nested-generator self-join runs over a 10,000-record
  slice instead of 2,000 (100M inner evaluations instead of 4M); the rest is unchanged.

Measured on a heavily shared machine (load 25-35); times are CPU seconds normalised
by a calibration run to a lightly loaded machine. Fastest of C++, Rust, Go and D per
input: 001 C++ 7.0 s (D 8.1, Rust 8.7), 002 Rust 6.6 s (C++ 10.0, Go 7.3), 003 C++
7.2 s (D 8.2, Rust 9.9). Peak RSS at most 131 MB (Go). SPEC.md's Limits line about reference run time now mentions the long tier.
