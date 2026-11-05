# json performance benchmark

SPEC.md allows one document of at most 2,000,000 bytes per input, so each input is a single
document of about 1.9-2.0 MB, which is the largest allowed. At that size the compiled
implementations take 20-50 ms (about 10-15 ms of that is process start-up), well under the
usual 0.3 s target. That is the spec's ceiling, and repeated runs are needed for stable numbers.
`python3 gen_bench.py` regenerates everything. Expected outputs come from `reference/main.py`
and are cross-checked against Python's `json` module.

- **001_mixed_nested_records**: about 2 MB of random records nested up to 9 levels (arrays,
  objects with occasional duplicate keys, all number forms including long digit strings and
  exponent normalisation, escaped strings, literals). A quarter of the records are
  pretty-printed with varied whitespace. This measures general parse and serialise throughput
  on an ordinary large document, and no single code path dominates.
- **002_string_heavy_unicode_escapes**: log-style records that are mostly long string values
  containing `\n`/`\t`/`\"`/`\\`, `\uXXXX` escapes, escaped surrogate pairs, raw multibyte
  UTF-8 and control characters. This measures UTF-8 validation, escape decoding and canonical
  re-escaping, the main per-byte costs for text-heavy JSON.
- **003_wide_objects_sort_dedup**: one 55k-member ID-keyed index object (`"user:0001234"`-style
  keys that share long prefixes, shuffled, about 10% repeated), followed by hundreds of wide
  objects with 200-3000 keys each. Keys come from a shared vocabulary that includes non-BMP and
  U+E000-U+FFFF characters, so they collide and need the UTF-16 ordering. This measures the
  algorithmically hardest part, which is sorting keys in UTF-16 order and removing duplicates
  with last-wins, at a realistic scale.

## Long tier

`python3 gen_bench.py --long` writes `bench-long/`: the same three documents (same generators, seeds 1101/1202/1303) ten times larger, about 19.9 MB each; in 003 the ID-keyed index object has 550,000 members instead of 55,000. Expected outputs come from `reference/main.py` and are cross-checked against Python's `json` module (45 s in total). SPEC.md's input cap is raised to 24 MB for the long tier only.

**This tier does not reach the 5 s target.** Canonicalisation is linear in the input and SPEC.md allows exactly one document per input, so the only lever is document size. At 20 MB the fastest builds need 0.14-0.6 s CPU (D 0.14 s on 002, Rust 0.26 s on 001, Rust 0.57 s on 003; 0.2-1.3 s wall on the loaded machine), with 75-330 MB RSS. Reaching 6 s would take documents of roughly 200-800 MB each, far beyond the disk budget, and about 3-12 GB RSS for the Go build and the Python reference (which needs about 20x the document size). It is kept as a 10x-larger best-effort tier. All five builds pass; the Python build takes 2-4 s and at most 410 MB. `bench-long/` is 96 MB.
