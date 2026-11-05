# toml performance benchmark

Regenerate with `python3 problems/toml/bench/gen_bench.py` (fixed seeds, Python 3.11+).
Expected outputs come from `reference/main.py`; every decode result is also
cross-checked against Python's `tomllib`, and the encode result is checked to
round-trip (decode(encode(x)) == x) and to parse identically with `tomllib`.
Run with `python3 run_tests.py toml --tests-dir problems/toml/bench -- <impl>/run.sh`.

SPEC.md caps a document at 8 MB and allows one document per input, so each
input is a single large document. Sizes are set so that bench/ stays near
30 MB with expected outputs (decoded tagged JSON is about twice the TOML size).

- **001_decode_cargo_lock** (4.0 MB TOML, ~12.9k packages): a Cargo.lock in the
  exact shape cargo writes — `[[package]]` array of tables, short string pairs,
  64-hex checksums, multi-line dependency arrays. Measures raw decode throughput
  on the most common real-world TOML file type: scanning, basic strings,
  array-of-tables appends and JSON output.
- **002_decode_dense_config** (3.3 MB TOML): a deep configuration document using
  the whole grammar — implicit tables made explicit later, nested
  `[[a.service]]`/`[[a.service.port]]` arrays of tables with sub-tables, dotted
  keys with spaces, quoted/unicode keys, inline tables, multi-line and literal
  strings with every escape, hex/octal/binary/underscored integers, floats
  needing 17-digit formatting, all four date-time kinds, and wide tables of
  inline-table rows that need key sorting. Stresses table resolution and
  scalar parsing/formatting rather than plain scanning; all values are
  realistic and within spec limits (integers fit in i64, fractional seconds
  have at most 6 digits).
- **003_encode_config_tree** (6.2 MB tagged JSON): encode mode on the tagged tree
  of a document like 002, with every object's members shuffled (allowed by
  §2.1), so the encoder must parse the JSON, classify nodes, sort keys, quote
  keys/strings and emit headers for a large nested tree.

Note: binary literals of 22+ digits and octal literals of 21 digits (both
within i64) in 002 are valid per SPEC.md and are accepted by the reference
and tomllib.

## Long tier

`python3 bench/gen_bench.py --long` writes `bench-long/`: the same three documents from the same generators (seeds 11001-11003), the decode inputs 4x larger (16.0 MB Cargo.lock, 13.2 MB dense config) and the encode input 3x larger (19.5 MB tagged JSON). Expected outputs come from `reference/main.py` with the same tomllib cross-checks and round-trip check as the short tier (47 s in total). SPEC.md's document cap is raised to 20 MB for the long tier only.

**This tier does not reach the 5 s target.** Both modes are linear in the document and SPEC.md allows one document per input. At this size the fastest builds need 0.14-0.3 s CPU (C++/Go/D 0.14-0.15 s on 001, Rust 0.29 s on 002, Rust 0.20 s on 003), with 100-185 MB RSS; 6 s would need documents of 300-600 MB each. It is kept as a best-effort tier, sized to stay near the 100 MB disk budget (`bench-long/` is 107 MB). All five builds pass; the Python build takes 1-4.5 s and at most 400 MB.
