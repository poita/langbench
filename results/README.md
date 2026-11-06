# Results

Agent effort for D and Go from the first sandboxed run, `run-20261105-101754`, with the six tasks of mime, fulltext and
svgraster rerun in `run-20261105-200008` after their test data changed (the implementations in
[`implementations/`](../implementations/)). Performance results and further languages will follow; this page
reports only what the runs measured. Every table can be regenerated with the command above it.

## The run

- **Languages:** D (LDC 1.41.0, dub 1.40.0) and Go 1.27.1.
- **Tasks:** all 40 problems once, plus three repetitions of bigint, buildsys, chip8, datalog, depresolve, jq,
  regex, sat, toml and webhooks: 60 tasks per language.
- **Agent:** Claude Sonnet 5.5 at high effort, in Claude Code 2.1.318; one
  headless session per task in a private sandboxed workspace, from `tools/task_prompt.txt`
  ([how runs work](../docs/generating.md)).
- **Verification:** each project rebuilt from a clean copy of its sources and run against the public tests and,
  for the five large problems, the held-out tests.
- **Rerun:** rep1:d:fulltext, rep1:d:mime, rep1:d:svgraster, rep1:go:fulltext, rep1:go:mime, rep1:go:svgraster were rerun with the same prompt, model and sandbox (at a later harness commit) once
  those problems' test data were replaced (generated mailboxes, a public-domain book, CC0 icons); the rerun
  replaces the first run's attempts at those tasks.
- **Usage:** $145 at API list prices for the 120 sessions counted.

## Agent effort

`python3 tools/agent_effort.py implementations/transcripts/run-20261105-101754.tar.gz implementations/transcripts/run-20261105-200008.tar.gz --baseline go`

Per problem, the median over repetitions; then the D/Go ratio on the same problem; then the geometric mean over
problems with a 95% bootstrap interval. Output tokens are the headline measure. An unfinished task counts as at
least as costly as the costliest finished task on its problem.

output tokens relative to Go, per problem (median over repetitions), geometric mean with 95% bootstrap interval over problems; below 1 is less effort

| Language | vs Go | 95% interval | Problems | Finished |
|---|---:|---:|---:|---:|
| Go | 1.00x | | | 59/60 |
| D | 1.13x | 1.08–1.19 | 40 | 60/60 |

turns relative to Go, per problem (median over repetitions), geometric mean with 95% bootstrap interval over problems; below 1 is less effort

| Language | vs Go | 95% interval | Problems | Finished |
|---|---:|---:|---:|---:|
| Go | 1.00x | | | 59/60 |
| D | 1.38x | 1.26–1.52 | 40 | 60/60 |

cost relative to Go, per problem (median over repetitions), geometric mean with 95% bootstrap interval over problems; below 1 is less effort

| Language | vs Go | 95% interval | Problems | Finished |
|---|---:|---:|---:|---:|
| Go | 1.00x | | | 59/60 |
| D | 1.19x | 1.13–1.25 | 40 | 60/60 |

Per agent, all problems pooled:

| Language | Agents | All tests pass | Turns / agent | Tool calls / agent | Output tokens / agent | Context tokens / agent | Cost / agent | Minutes / agent | Inference | Build | Unit tests | Harness tests | Other shell | Files |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Go | 60 | 59/60 | 18.8 | 18.6 | 59k | 1.79M | $1.11 | 9.1 | 73% | 5% | 9% | 6% | 8% | 0% |
| D | 60 | 60/60 | 25.6 | 25.5 | 65k | 2.76M | $1.31 | 10.4 | 78% | 2% | 4% | 10% | 7% | 0% |

Relative to Go (per agent):

| Language | Turns | Tool calls | Output tokens | Context tokens | Time |
|---|---:|---:|---:|---:|---:|
| D | 1.37x | 1.37x | 1.11x | 1.54x | 1.14x |

## Completion and audit

`implementations/results/<run>.json`, `implementations/audit/<run>.json`

- D: 60 of 60 tasks pass every public and held-out test on a
  clean build; Go: 59 of 60.
- Not passing: rep1:go:cardgame: cardgame: 117/117 passed; held-out cardgame: 291/292 passed.
- Audit: no integrity findings. Blocked attempts (reads the sandbox refused): 1;
  non-default optimisation settings in build files: 1; uses of a standard-library
  facility the problem's spec rules out, all in unit tests: 8; third-party
  dependencies: 0.

## Code size

`python3 tools/code_stats.py implementations`

| Language | Projects | Code lines (median) | Test lines (median) | Test share (median) |
|---|---:|---:|---:|---:|
| Go | 60 | 1380 | 526 | 28% |
| D | 60 | 1526 | 382 | 21% |

## By problem

Medians over repetitions; "Finished" counts tasks that pass on a clean build.

| Problem | Runs | Go output tokens | D output tokens | D/Go | Go turns | D turns | Go finished | D finished |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| bigint | 3 | 22.1k | 23.7k | 1.07 | 12 | 12 | 3/3 | 3/3 |
| buildsys | 3 | 114.6k | 120.6k | 1.05 | 37 | 39 | 3/3 | 3/3 |
| cardgame | 1 | 155.9k | 169.3k | 1.09 | 45 | 56 | 0/1 | 1/1 |
| chess-perft | 1 | 42.6k | 50.5k | 1.18 | 16 | 17 | 1/1 | 1/1 |
| chip8 | 3 | 19.0k | 21.8k | 1.15 | 9 | 15 | 3/3 | 3/3 |
| commonmark | 1 | 92.9k | 100.1k | 1.08 | 33 | 32 | 1/1 | 1/1 |
| datalog | 3 | 47.7k | 45.0k | 0.94 | 13 | 12 | 3/3 | 3/3 |
| depresolve | 3 | 27.7k | 23.4k | 0.84 | 8 | 14 | 3/3 | 3/3 |
| diff | 1 | 25.3k | 33.5k | 1.32 | 9 | 20 | 1/1 | 1/1 |
| fulltext | 1 | 44.6k | 55.5k | 1.25 | 15 | 25 | 1/1 | 1/1 |
| gitrepo | 1 | 71.7k | 75.7k | 1.06 | 21 | 30 | 1/1 | 1/1 |
| inflate | 1 | 43.5k | 34.0k | 0.78 | 15 | 20 | 1/1 | 1/1 |
| jq | 3 | 70.4k | 85.4k | 1.21 | 19 | 34 | 3/3 | 3/3 |
| json | 1 | 24.7k | 37.8k | 1.53 | 9 | 18 | 1/1 | 1/1 |
| jsonschema | 1 | 91.4k | 94.6k | 1.04 | 22 | 21 | 1/1 | 1/1 |
| kvstore | 1 | 88.3k | 114.2k | 1.29 | 25 | 30 | 1/1 | 1/1 |
| langvm | 1 | 291.2k | 288.0k | 0.99 | 90 | 105 | 1/1 | 1/1 |
| linalg | 1 | 37.4k | 49.4k | 1.32 | 11 | 23 | 1/1 | 1/1 |
| mime | 1 | 71.0k | 73.7k | 1.04 | 19 | 30 | 1/1 | 1/1 |
| minisql | 1 | 51.1k | 66.7k | 1.31 | 16 | 24 | 1/1 | 1/1 |
| orderbook | 1 | 33.8k | 32.8k | 0.97 | 11 | 15 | 1/1 | 1/1 |
| ordered-map | 1 | 18.5k | 22.6k | 1.22 | 9 | 9 | 1/1 | 1/1 |
| protowire | 1 | 57.0k | 71.8k | 1.26 | 18 | 24 | 1/1 | 1/1 |
| qrcode | 1 | 22.2k | 28.9k | 1.30 | 9 | 12 | 1/1 | 1/1 |
| regex | 3 | 39.7k | 45.4k | 1.14 | 17 | 21 | 3/3 | 3/3 |
| rrule | 1 | 40.6k | 45.0k | 1.11 | 16 | 25 | 1/1 | 1/1 |
| rubiks | 1 | 49.9k | 60.2k | 1.21 | 17 | 21 | 1/1 | 1/1 |
| sat | 3 | 22.7k | 41.0k | 1.81 | 9 | 29 | 3/3 | 3/3 |
| scheme | 1 | 53.0k | 62.1k | 1.17 | 20 | 30 | 1/1 | 1/1 |
| sitegen | 1 | 200.0k | 180.3k | 0.90 | 54 | 50 | 1/1 | 1/1 |
| softfloat | 1 | 18.6k | 18.7k | 1.00 | 8 | 11 | 1/1 | 1/1 |
| spreadsheet | 1 | 38.7k | 45.7k | 1.18 | 11 | 26 | 1/1 | 1/1 |
| sqlitefile | 1 | 79.8k | 76.0k | 0.95 | 25 | 25 | 1/1 | 1/1 |
| svgraster | 1 | 71.1k | 84.9k | 1.19 | 15 | 29 | 1/1 | 1/1 |
| template | 1 | 80.3k | 112.3k | 1.40 | 18 | 45 | 1/1 | 1/1 |
| textbuffer | 1 | 50.7k | 53.5k | 1.06 | 26 | 19 | 1/1 | 1/1 |
| toml | 3 | 47.1k | 47.8k | 1.01 | 14 | 20 | 3/3 | 3/3 |
| typeinfer | 1 | 51.3k | 54.3k | 1.06 | 17 | 20 | 1/1 | 1/1 |
| typeset | 1 | 154.4k | 188.2k | 1.22 | 42 | 59 | 1/1 | 1/1 |
| webhooks | 3 | 45.6k | 54.0k | 1.18 | 14 | 18 | 3/3 | 3/3 |
