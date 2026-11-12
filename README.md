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

### Regenerate the committed implementations

```
git rm -rq implementations    # start empty, so no old files mix with the new ones

# a sandbox outside this checkout; give it a neutral name, since agents see its path
python3 tools/impl_run.py sandbox ~/work/run1
python3 tools/impl_run.py launch ~/work/run1 --auth subscription   # 420 sessions, roughly 12 hours
python3 tools/impl_run.py finish ~/work/run1 --dest implementations --stage

make results                  # rewrite results/README.md
```

`run-config.json` sets the languages (C++, Rust, Go, D, Python, Haskell and
Clojure), model, effort and repetitions; `--langs` and `--problems` narrow a
run. `--auth subscription` uses your Claude Code login and plan; leave it out
to use `ANTHROPIC_API_KEY`. Either way the sessions load none of your
settings, memory or MCP servers. Agents are not deterministic, so this repeats
the procedure, not the exact code. The committed run was stopped after 338 of
its 420 sessions to save usage; the 82 that did not run are all repetitions,
and rerunning `launch` on its sandbox would add them.

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

The current run covers seven languages: all 40 problems in each, plus most
second repetitions of ten, written by Claude Sonnet 5.5 in Claude Code, one
sandboxed session per task. It measures agent effort; performance on stable
hardware will follow.

| Relative to Go, paired over 40 problems | Output tokens | Turns | Cost |
|---|---:|---:|---:|
| Python | 0.89× (0.83–0.96) | 0.94× | 0.91× |
| Rust | 1.07× (1.02–1.12) | 0.98× | 1.07× |
| D | 1.15× (1.07–1.25) | 1.48× | 1.22× |
| C++ | 1.18× (1.11–1.25) | 1.09× | 1.18× |
| Haskell | 1.19× (1.10–1.28) | 1.49× | 1.26× |
| Clojure | 1.27× (1.19–1.35) | 1.81× | 1.39× |

Brackets are 95% intervals. On a clean rebuild, 335 of the 338 projects pass
every public and held-out test. Tables, per-problem numbers, code size and the
commands that produce them: [results/](results/README.md).

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
