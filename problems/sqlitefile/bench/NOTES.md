# sqlitefile performance benchmark

Regenerate with `python3 problems/sqlitefile/bench/gen_bench.py` (deterministic;
about 2 minutes, mostly the sqlite3 cross-check; `--no-oracle` skips it).
Run with `python3 run_tests.py sqlitefile --tests-dir problems/sqlitefile/bench -- <impl>/run.sh`.
Expected outputs come from `reference/main.py`, and the generator checks every query
against the `sqlite3` shell. All 25 implementations (cpp/rust/go/python/d across
impls/, projects/ and runs/rep1-3) produce identical output on all three inputs.

* **001_airports_scan**: the full OurAirports import (86k airports, 48k runways,
  4096-byte pages, 10.5 MB, indexes dropped), with 22 analytic queries. Each query
  scans a whole table and combines WHERE filters, ORDER BY on text, integer and real
  columns, and LIMIT. This measures raw pager, B-tree and record-decode throughput,
  along with sorting. These are the reports people really run against a real
  dataset, and every query has to read every row.
* **002_index_lookups**: a trimmed OurAirports import in 1024-byte pages (deep
  B-trees, 14.8 MB) with six indexes, and 999 `INDEX` lookups. The lookups use
  unique text keys (ident, IATA), integer keys (some given as numeric text, to
  exercise affinity), and multi-row keys: cities, and regions with 20-600 airports
  whose runs of equal keys span interior index pages. Each match is followed by a
  rowid descent into the table. This tests index descent and in-order runs rather
  than scanning, so an implementation that walks the whole index pays for it.
  It is the lightest case (about 0.2 s compiled) because point lookups are cheap
  and both the 999-query cap and the size budget limit how many rows can be printed.
* **003_chinook_mixed**: Chinook (1 MB) with 999 seeded mixed queries in an
  application-like mix. The mix is roughly 45% FK index lookups, 45% filtered
  selects and sorts on Track, Invoice, InvoiceLine and Customer, and the rest
  COUNT, `.schema` and `.tables`. Each query is small, so this measures per-query
  overhead: re-parsing the schema, re-reading pages, writing 999 result files.
  It complements the bulk scans in 001.

## Long tier

`python3 gen_bench.py --long` writes `../bench-long/` (same names, same databases;
expected outputs from the reference, every query cross-checked against `sqlite3`;
about 30 minutes). SPEC.md is unchanged: its 999-query cap is tied to the three-digit
`NNN.txt` result names (implementations may rely on it), so the long tier keeps at most
999 queries per input and makes the queries heavier instead.

- **001_airports_scan**: 999 full-table scans instead of 22, drawn from the same 22
  report shapes with seeded parameters (countries, regions, cities, thresholds,
  surfaces); every fifth query is one of the whole-table sorts (`ORDER BY name`,
  `ORDER BY width_ft DESC`). Every query reads every row of its table.
- **002_index_lookups**: 999 lookups with the same mix, but region keys drawn from the
  regions with 300-5,000 airports (longer equal-key runs over interior index pages).
- **003_chinook_mixed**: 999 queries with the filtered-select and sort templates four
  times as frequent as in the short mix.

With the 999-query cap, 002 and 003 are bound by the query count (and 002 also by its
output: every matched row is printed), so they do **not** reach the 5 s target
(about 0.2 s each). Raising the cap would change the output-naming contract.

Measured on a heavily shared machine; times are CPU seconds normalised by a calibration
run to a lightly loaded machine: 001 Rust 8.9 s (C++ 11.3, D 12.7, Go 27.5), 002 Rust
0.18 s, 003 Rust 0.14 s. Peak RSS at most 264 MB (Rust, 001). Size 52 MB of file data
(60 MB on disk).
