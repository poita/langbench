# langbench

A benchmark of programming languages as written by coding agents. Agents
implement forty well-specified problems in each language; langbench then
measures how well that code performs and how effectively the agents wrote it.

## Why agent-written code

Language benchmarks usually compare code written by people, and its quality
varies by language and author, so they measure the authors as much as the
languages. Here every implementation is written by a coding agent from the same
spec and the same prompt. Quality is consistent across languages, at the level
an agent reaches in each one, which is now how most code is written. That
allows two measurements without author bias:

- **Performance of agent-written code**: cycles, instructions, wall time and
  memory on heavy, realistic inputs. Each problem's `APPROACH.md` fixes the
  algorithms and their complexity, but not how the code is written, so
  differences come from the language, its compiler and its runtime, and from
  how agents naturally write it, rather than from different algorithms.
- **Agent effectiveness**: correctness on public and held-out tests, and the tool
  calls, tokens and time an agent needs to get there.

Implementations are only ever written by agents, through `tools/impl_run.py`; a
hand-written one would bring back the author bias.

## What's here

| Path | Contents |
|---|---|
| `problems/` | 40 problems ([list](problems/README.md)): spec, required approach, public tests, benchmark generator, Python reference |
| `run-config.json`, `tools/task_prompt.txt` | The configuration of the committed run and the prompt each agent gets |
| `implementations/` | Agent-written implementations (so far D and Go), with the run's record (`run.json`), prompts, transcript archive, audit and test results |
| `lbench` | Builds implementations with chosen toolchains and benchmarks them |
| `tools/` | Run helpers, language comparisons (`compare.py`, `agent_effort.py`) and repository checks |
| `results/` | Results of the runs so far, generated from `implementations/` by `make results` |

The problems are fifteen ~1,000-line algorithmic tasks, ten text and semantics
tasks, ten multi-thousand-line real-world libraries on real data, and five
large invented-spec systems with held-out tests.

## Quick start

Requirements: Python 3.9+, Claude Code (signed in, or with `ANTHROPIC_API_KEY`
set), and the toolchains of the languages you generate. Hardware counters come
from `/usr/bin/time -l` on macOS and `perf stat` on Linux.

### Regenerate the committed implementations (D and Go)

```
git rm -rq implementations    # start empty, so no old files mix with the new ones

# a sandbox outside this checkout; give it a neutral name, since agents see its path
python3 tools/impl_run.py sandbox ~/work/run1 --langs d,go
python3 tools/impl_run.py launch ~/work/run1 --auth subscription   # 120 sessions, about 3.5 hours
python3 tools/impl_run.py finish ~/work/run1 --dest implementations --stage

make results                  # rewrite results/README.md
```

`--auth subscription` uses your Claude Code login and plan; leave it out to use
`ANTHROPIC_API_KEY`. Either way the sessions load none of your settings,
memory or MCP servers. `run-config.json` sets everything else (model, effort,
repetitions). Agents are not deterministic, so this repeats the procedure, not
the exact code. The committed record has a second, six-session run only
because three problems' test data changed after the first; the problems as
they are now need just the one run.

### Every language

Leave out `--langs` to run every language in `run-config.json` (C++, Rust, Go,
D, Python, Haskell and Clojure): 420 sessions and roughly 12 hours.

### Measure

```
# agent effectiveness: turns, output tokens and cost against a baseline language
python3 tools/agent_effort.py implementations/transcripts/*.tar.gz --baseline go

# performance
make bench-long                               # generate the benchmark inputs once (slow)
./lbench build --tag new --suite all --roots implementations/rep1
./lbench run --tag new
python3 tools/compare.py new --baseline go
```

[docs/generating.md](docs/generating.md) covers the sandbox, the audit, the
run configuration and cost. [docs/benchmarking.md](docs/benchmarking.md)
covers `lbench`: comparing languages, comparing toolchains (`--toolchain
LANG=PATH` for any language), suites, and measurement noise.

## Results so far

The first run covers D and Go: all 40 problems, plus three repetitions of ten,
written by Claude Sonnet 5.5 in Claude Code, one sandboxed session per task
(the three problems whose test data changed since were rerun).
It measures agent effort; performance on stable hardware and more languages
will follow.

| D relative to Go | Paired over 40 problems | 95% interval |
|---|---:|---:|
| Output tokens | 1.13× | 1.08–1.19 |
| Turns | 1.38× | 1.26–1.52 |
| Cost | 1.19× | 1.13–1.25 |

On a clean rebuild, D passes every public and held-out test in 60 of 60 tasks
and Go in 59 of 60. Tables, per-problem numbers and the commands that produce
them: [results/](results/README.md).

## Held-out tests

The five large problems keep most of their tests in `problems/<slug>/heldout/`.
Agents never see them: the sandbox gives each agent only its problem's visible
tests, so the held-out tests check whether an implementation follows the spec
rather than just the tests it saw. `tools/impl_run.py finish` scores
implementations on both. The held-out tests are public; a test leaking into a
model's training data would help every language alike.

## Development

`make check` checks problem structure, the run configuration, run
provenance and the unit tests; `make references` also runs every reference
implementation on its public tests. `CONVENTIONS.md` is what implementers (the
agents) read: the I/O contract and project layout; `problems/README.md` covers
the rest of each problem's files.

## Licence

MIT (`LICENSE`), except third-party data used by some problems, which keeps
its own licence: among them CC BY-SA 4.0 (the CommonMark spec examples),
CC BY 4.0, Apache-2.0, BSD-3-Clause, BlueOak-1.0.0, the Artistic License and
CC0. [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) lists every source
and its licence; each licence text sits next to its data.
