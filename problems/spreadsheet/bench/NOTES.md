# spreadsheet performance benchmark

Regenerate with `python3 problems/spreadsheet/bench/gen_bench.py` (fixed seeds). Expected
outputs come from `reference/main.py`; the generator also checks that no displayed number is
an exact 10-digit rounding tie. Every input stays within the SPEC's stated scale (at most about
70,000 commands / 1.3 MB, ranges of at most 10,000 cells, chains of at most 10,000 cells).
Run: `python3 run_tests.py spreadsheet --tests-dir problems/spreadsheet/bench -- <impl>/run.sh`

- `001_ledger_rollup` — a 4,800-row transaction ledger (43k cells: literals, strings, per-row
  arithmetic, nested IF, string concatenation, 12-row moving AVG ranges, a 4,800-deep running
  balance chain, whole-column SUM/AVG/MAX/MIN/COUNT summaries) followed by 1,500 typical user
  edits (corrections mostly on recent rows, relabels, lookups, occasional global rate/threshold
  changes) and a 43k-line dump. Measures parse/build throughput plus ordinary incremental
  recalculation with long chains and large ranges; nothing is degenerate.
- `002_lattice_recalc_cycles` — a 100x100 lattice where each interior cell reads its left, upper
  and upper-left neighbours (arithmetic, MAX, SUM, IF, AVG), plus 100 column-SUM ranges and a
  grand total. 260 rounds edit the seed corner (re-evaluating ~10k dependants), overwrite and
  restore interior cells, and open and close reference cycles spanning up to the whole lattice.
  This is the algorithmically hardest part: dirty-set discovery, topological re-evaluation and
  SCC/cycle detection over a dense 10k-node DAG.
- `003_random_workbook_mixed` — 30,000 commands from the same random-workbook generator the
  public tests use (`gen_tests.Gen`), over a 16x40 sheet: every operator, IF, aggregates over
  random ranges, frequent cycles, clears, gets and occasional dumps. A realistic mixed workload
  with heavy, irregular fan-out and constant cycle creation/removal.

## Long tier

`python3 bench/gen_bench.py --long` writes `bench-long/` with the same three workbooks, scaled by work rather than size:

- 001 keeps the 4,800-row ledger and runs 40,000 user edits instead of 1,500. It uses its own seed (5111), one-decimal
  global rates (1.0/1.1/1.2) and a 10-row moving average instead of 12. With the short tier's two-decimal rates and
  12-row average, the running balance (~1.5 million) and `I = E - H` carry four exact decimals, and over tens of
  thousands of `get`s some displayed values land on exact 10-digit rounding ties, which the generator rejects. With
  these choices they have at most 10 significant digits.
- 002 keeps the 100x100 lattice and runs 6,800 edit/cycle rounds instead of 260.
- 003 runs the same random-workbook generator for 250,000 commands instead of 30,000.

SPEC.md's scale note now allows up to about 1,000,000 commands (20 MB of input). Expected outputs come from
`reference/main.py`, with the same rounding-tie check (about 38 min for all three).

Times are user CPU (single run at load average ~10-15 on 8 cores):

| input | fastest (user s) | others (user s) | peak RSS compiled | python (wall / user, RSS) | size |
| --- | --- | --- | --- | --- | --- |
| 001_ledger_rollup | cpp 7.4 | rust 7.7, go 9.6, d 9.9 | 137 MB | 166 s / 164 s, 114 MB | 4.2 MB |
| 002_lattice_recalc_cycles | rust 7.0 | d 8.5, go 9.0, cpp 10.0 | 160 MB | 186 s / 183 s, 302 MB | 41 MB |
| 003_random_workbook_mixed | rust 8.1 | cpp 9.1, go 10.6, d 13.2 | 52 MB | 112 s / 110 s, 41 MB | 4.9 MB |

`bench-long/` is 48 MB. All five implementations pass all three.
