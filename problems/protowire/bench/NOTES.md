# protowire performance benchmark

Regenerate with `python3 gen_bench.py [--oracle]`. The generator is deterministic, with fixed seeds. Expected outputs come from `reference/main.py`. With `--oracle`, every request is also cross-checked against protoc and the protobuf runtime, as `gen_tests.py` does. That check passed with 0 disagreements. Each input is about 5 MB, which stays under SPEC.md's "total input under 6 MB" limit. Every payload is at most 0.6 MB and the nesting depth stays at or below 64. Because of these limits, compiled implementations take about 0.07–0.2 s per input, which is mostly real codec work rather than process start-up.

- **001_decode_telemetry_batches**: 75 `decode` requests for log/telemetry `Batch` messages. Each batch holds nested `Event`s with strings (some with escapes and non-ASCII text), packed sint64, fixed32 and uint32 arrays, attributes, bytes and sub-headers. Every 30th batch is large, close to the 0.54 MB payload limit. A small fraction of the input is unknown fields, unpacked repeats, concatenated (merged) batches or truncated streams. This measures decode throughput (varints, length prefixes, text rendering with escaping) on the kind of data a wire codec mostly handles.
- **002_encode_syntax_trees**: 29 `encode` requests, each a syntax-tree `Module` of up to about 480 KB of text. The trees are recursive `Node`s, and 12% of declarations are deep left-nested expression chains up to 58 levels deep. Some requests use compact or extra spacing or shuffled field order. This measures the text parser and the hardest part of encoding: computing nested length prefixes without re-encoding each level, on realistic deep but in-limit trees.
- **003_mixed_wide_schema_stream**: 8,015 mixed requests (about 45% encode and 55% decode) over a random schema of 50 messages with up to 64 fields each. Field numbers reach 536870911. The decodes include noise (unknown fields, groups, unpacked repeats, non-minimal varints), and about 4% of requests are malformed, giving 292 `error` lines. This measures per-request overhead, field lookup in wide messages and error paths, like an RPC gateway handling varied traffic.

## Long tier

`python3 gen_bench.py --long` writes `../bench-long/` (same names; expected outputs from
`reference/main.py`, about 1 minute). SPEC.md's per-test input limit is raised from
6 MB to 50 MB for this tier; payload size and nesting limits are unchanged. The same
three generators run with larger byte budgets: 001 299 telemetry batches (23 MB),
002 156 syntax-tree modules (24 MB), 003 77,118 mixed requests (48 MB, 2,630 errors).

A wire codec costs a fixed amount per byte, so this problem is bound by its input
size: 5 s would need well over 500 MB of hex per input. The long tier does **not**
reach the 5 s target: the fastest build takes 0.10 s, 0.10 s and 0.37 s (C++; Rust
0.10, 0.15, 0.39; CPU seconds normalised to a lightly loaded machine). Peak RSS at most
216 MB (Go). Size on disk 170 MB.
