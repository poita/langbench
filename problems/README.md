# Problems

| Slug | Task | Checked by |
|------|------|-----------|
| `chess-perft` | Legal chess move generation, perft / divide counts | exact match |
| `regex` | Backtracking regex engine for a defined subset | exact match |
| `bigint` | Arbitrary-precision integer arithmetic | exact match |
| `json` | RFC 8259 parser + canonical serializer | exact match |
| `inflate` | DEFLATE (RFC 1951) decoder | exact match |
| `qrcode` | QR code encoder (all versions, ECLs, masks) | exact match |
| `softfloat` | Software IEEE-754 binary32 add/sub/mul/div/sqrt | exact match |
| `sat` | CDCL SAT solver on DIMACS CNF | verifier |
| `scheme` | Scheme interpreter with proper tail calls | exact match |
| `spreadsheet` | Formula engine with incremental recalculation | exact match |
| `chip8` | CHIP-8 emulator | exact match |
| `diff` | Myers diff + patch | verifier |
| `ordered-map` | Balanced ordered map with rank/select/range | exact match |
| `rubiks` | Rubik's cube solver (Thistlethwaite/Kociemba) | verifier |
| `minisql` | SQL subset engine, cross-checked against SQLite | exact match |
| `commonmark` | CommonMark subset to HTML, cross-checked against cmark | exact match |
| `typeinfer` | Hindley-Milner type inference, cross-checked against OCaml | exact match |
| `datalog` | Datalog with stratified negation, semi-naive evaluation | exact match |
| `rrule` | RFC 5545 recurrence expansion, cross-checked against dateutil | exact match |
| `orderbook` | Limit order book matching engine | exact match |
| `depresolve` | Semver package dependency resolver with backtracking | verifier |
| `textbuffer` | Text buffer with undo, redo and multiple cursors | exact match |
| `protowire` | Protobuf-style wire codec, cross-checked against protoc | exact match |
| `jq` | jq-subset query language, cross-checked against jq | exact match |
| `template` | Jinja-style template engine, cross-checked against Jinja2 | exact match |
| `sitegen` | Static site generator (Markdown, templates, tags, feed) on real texts | tree match |
| `webhooks` | Standard Webhooks signing/verification plus delivery simulator | exact match |
| `linalg` | Dense linear algebra library on SuiteSparse matrices, checked against numpy | verifier |
| `toml` | TOML 1.0 parser and serializer on the official toml-test suite | exact match |
| `sqlitefile` | SQLite database file reader on real databases, checked against sqlite3 | tree match |
| `gitrepo` | Git repository reader (SHA-1, inflate, packfiles) on real repos, checked against git | tree match |
| `mime` | MIME email parser on mailing-list archives, checked against Python's email package | tree match |
| `fulltext` | Full-text search engine with BM25 on Project Gutenberg texts | verifier |
| `svgraster` | SVG rasteriser on real icon sets, checked against resvg | verifier |
| `jsonschema` | JSON Schema 2020-12 validator on the official test suite | exact match |
| `langvm` | Compiler and stack VM for Vellum, an invented typed language (held-out tests) | exact match |
| `kvstore` | Tessera: a transactional document store with WAL, B+tree and secondary indexes (held-out tests) | tree match |
| `cardgame` | Spiremark: the full rules engine of an invented duelling-card game (held-out tests) | exact match |
| `typeset` | Codexa: a typesetting engine with total-fit line breaking and hyphenation (held-out tests) | tree match |
| `buildsys` | Kiln: an incremental build system with its own build language (held-out tests) | tree match |


## The test harness

`run_tests.py` runs one implementation against a problem's tests; agents use it
to check their work, and `tools/impl_run.py` uses it to score held-out tests.
`CONVENTIONS.md` defines the I/O contract (stdin/stdout, or an input path and an
output directory) and the project layout every implementation follows.

```
python3 run_tests.py <slug> -- <command that runs the implementation>
python3 run_tests.py sat -- python3 problems/sat/reference/main.py
```

Options: `--timeout SECS` (no limit by default), `-v` to list passing tests and
show diffs, `--filter TEXT` to run a subset, `--tests-dir DIR` for another test
set. Regenerate a problem's tests with `cd problems/<slug> && python3 gen_tests.py`.

## Problem layout

`CONVENTIONS.md` is written for implementers, and it is what agents read; it
covers `SPEC.md`, `APPROACH.md`, the tests, `verify.py`, the I/O rules and the
`build.sh`/`run.sh` scripts. Each problem directory also holds files agents never
see (the sandbox leaves them out):

- `reference/`: the reference implementation (Python, standard library only)
  that produced the expected outputs: `python3 reference/main.py < tests/x.in`.
  It validates the harness; it is not what is measured.
- `gen_tests.py`: regenerates the generated tests deterministically (fixed
  seeds) and their expected outputs via the reference.
- `bench/gen_bench.py`: generates the benchmark inputs (`make bench`,
  `make bench-long`).
- `verify.py` must depend only on the Python standard library, and vendored
  real-world corpora in `tests/` stay under about 50 MB per problem.
- Third-party data keeps its licence text next to it in `corpus/`, and goes
  into the top-level `THIRD_PARTY_NOTICES.md`. Agents get `tests/` without
  `corpus/`, so `gen_tests.py` also copies `corpus/tests-notice.md` to
  `tests/THIRD_PARTY.md` (which tests use what, under which licence) and
  the licence texts it names into `tests/`.

`APPROACH.md` fixes the algorithms and data representations so that
implementations in different languages do the same work and performance
comparisons measure the language rather than each implementer's design. Agents
see it as an ordinary design document.

## Held-out tests

The five large problems keep most of their tests in `heldout/`, with the same
layout as `tests/`; `gen_tests.py` splits each suite between the two with one
shared numbering. Agents never see `heldout/`, and `tools/impl_run.py finish`
scores implementations on it. By hand:
`python3 run_tests.py <slug> --tests-dir problems/<slug>/heldout -- <cmd>`.
