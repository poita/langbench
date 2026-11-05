# typeinfer performance benchmark

Regenerate with `python3 gen_bench.py` (fixed seeds; expected outputs from
`reference/main.py`, about two minutes). All inputs respect SPEC.md's limits
(at most 1.2 MB and 6000 declarations).

- `001_module_throughput` — 5857 declarations, 1.2 MB: a type-directed random library of mostly well-typed
  functions that use polymorphic helpers (map/fold/compose/twice/append/zip...) at many types, mixed with a
  state-monad combinator library; about 3% of declarations have one type error. This is ordinary code, so it
  measures parse and inference throughput. The 1.2 MB input limit caps it at about 0.1 s for compiled code.
- `002_anf_let_chains` — 9 functions, each a chain of 1500–2900 nested `let ... in` bindings like A-normal-form
  compiler output, with local polymorphic helpers, `let rec` loops and arithmetic. A threaded state value grows
  along the chain, so each let generalises and instantiates a type that keeps getting larger. The cost is
  quadratic in chain length, and the input tests whether generalisation and instantiation scale (spec: 3000
  nested lets).
- `003_big_types` — generalised values with up to 2^12 leaves and thousands of type variables (pair towers and
  mixed towers), used 1100 times in lists, `map`/`fold`, projections and a few failing unifications. Most
  results are small, so the time goes to instantiating and unifying large types, not to printing them. A few
  large types are printed at the end (output 578 KB, within the spec's ~600 KB).

## Long tier

`python3 gen_bench.py --long` writes `bench-long/` (same seeds as the short tier, longer streams; expected outputs from `reference/main.py`, 58 minutes in total on a heavily loaded machine, 490 MB peak RSS):

- `001_module_throughput` — the same module stream continued to 12 MB and 59,000 declarations (10x). **This input does not reach the 5 s target**: inference of ordinary code is linear in the source, one program per input is allowed, and the fastest builds need only 0.33 s (Rust, C++ 0.34 s) at 12 MB while using 250-580 MB RSS. Reaching 6 s would need a source of roughly 200 MB, which would exceed the disk budget and push the compiled builds to 4-10 GB RSS; the reference is also superlinear here (18 minutes at 12 MB, an estimated 70 at 24 MB). It is kept as a 10x-larger best-effort input.
- `002_anf_let_chains` — 48 let chains of the same lengths (1500-2900 nested lets; the 3000-let nesting limit is unchanged) instead of 9, 6 MB.
- `003_big_types` — the short input's 1100 uses, then 16,000 more uses of the `p` towers (`pair` towers whose types have 2^10-2^12 leaves but share one subterm per level), mostly in lists of 6-16 copies plus `map`/`fold`/projection uses and failing unifications. The `q`-tower uses of the short input allocate a lot (Go needs 1.6 GB on the short input already); the shared towers make the added work unification of large types rather than allocation, so memory stays bounded while the time grows.

Measured on a heavily loaded 8-core M-series Mac (CPU time is the reliable figure; wall time was 1.3-2x higher). Fastest per input: 001 Rust 0.33 s user (0.66 s wall); 002 C++ 7.9 s user (10.3 s wall; D 8.5 s, Rust 8.5 s, Go 10.2 s); 003 C++ 6.3 s user (11.8 s wall; D 8.1 s, Rust 8.6 s, Go 10.2 s). Peak RSS: Go 1.9 GB on 003 (C++ 1.06 GB, D 0.9 GB, Rust 0.37 GB), at most 700 MB elsewhere. The Python build passes all three (527 s in total, at most 410 MB RSS). `bench-long/` is 21 MB. SPEC.md's limits now allow 12 MB and 60,000 declarations in the long tier, and say that the largest long-tier output is about 2.4 MB.
