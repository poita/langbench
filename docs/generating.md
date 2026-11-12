# Generating implementations

Implementations are written only by coding agents: one headless Claude Code
session per (language, problem, repetition), started exactly as a person would
start Claude Code with a task. Each session gets the prompt in
`tools/task_prompt.txt`: build a standalone project (library, CLI, README,
automated tests, `build.sh`, `run.sh`) from the problem's `SPEC.md`, using the
design in its `APPROACH.md`, done when the visible tests and its own tests pass.
Only the standard library may be used, apart from a test framework for the
tests: each language's usual one is installed (GoogleTest for C++, pytest for
Python, hspec, tasty and QuickCheck for Haskell, the Cognitect test-runner for
Clojure; the others have one built in), and the prompt names it. The
prompt reads like an ordinary task; every language gets the same text apart from
its name and toolchain.

A run is reproducible from three committed things: `run-config.json` (what to
run), `tools/task_prompt.txt` (what each agent is told) and `tools/impl_run.py`
with `tools/runner.py` (where and how agents run). `run.json` records everything
else that can differ: the harness commit, Claude Code version, OS, toolchain
versions, model, effort, authentication and a hash of every prompt.

The committed runs were made before this repository was published, so the
harness commits in their `run.json` belong to the project's earlier, private
history. Between those commits and publication, what agents see changed only
in the test data of mime, fulltext and svgraster (which the second run redid)
and in the licence files added beside test data; how `finish` copies
projects changed as well, but not what agents were asked or shown.

## Requirements

- Claude Code, signed in or with `ANTHROPIC_API_KEY` set. By default the run
  uses the environment's credentials (an `ANTHROPIC_API_KEY` wins if set);
  `launch --auth subscription` drops API credentials so the run uses your
  Claude Code login and plan. Either way the sessions load none of your
  settings, memory, CLAUDE.md files, plugins or MCP servers (claude.ai
  connectors included). A full run is a lot of usage for a plan; tasks that hit
  a usage limit are retried after a pause.
- The toolchains of the languages you generate: a C++ compiler and CMake,
  Rust (cargo), Go, D (LDC and dub), Python 3, Haskell (GHC and cabal) and
  Clojure (the clojure CLI and a JDK). Their versions are detected and written
  into the prompt and the run record. GoogleTest must be installed for C++.
  Agents have no network, so staging a run downloads, once, what the other
  languages' test frameworks need into the sandbox's `tools/`: pytest's wheels
  (each Python workspace gets its own virtual environment with pytest), Clojure
  and the Cognitect test-runner (each Clojure workspace gets a copy), and the
  Haskell test frameworks as a local package repository plus a cabal store
  built from it (Haskell workspaces read the store; it is the only thing from
  outside the workspace they read).
- macOS or Linux, for Claude Code's sandbox (Seatbelt on macOS; bubblewrap on
  Linux).

## A run, end to end

```
python3 tools/impl_run.py sandbox ~/work/run1     # stage the sandbox
python3 tools/impl_run.py launch ~/work/run1      # run every task (hours)
python3 tools/impl_run.py finish ~/work/run1 --dest implementations --stage
```

1. **`sandbox DIR`** stages a sandbox outside this checkout. Agents see its
   path, so give it a neutral name (not "langbench" or "benchmark"). It holds
   a read-only master copy of what agents may see (`CONVENTIONS.md`,
   `run_tests.py`, and for every problem only `SPEC.md`, `APPROACH.md`, the
   visible tests and the data they use) and one private workspace per task,
   `DIR/w/<id>/`, whose opaque name reveals neither language nor repetition.
   A workspace holds hard links to the top-level files, its own problem, and
   the specs its problem refers to; the agent builds its project in
   `<workspace>/<slug>/` and keeps scratch files in `<workspace>/scratch/`.
   Reference implementations, test generators, benchmark inputs, other tasks
   and the held-out tests are out of reach. Hashes of every harness file, in the
   master copy and each workspace, are in `DIR/harness.json`; `DIR/tasks.json`
   maps tasks to workspaces; `DIR/args.json` holds the run's arguments
   (`run-config.json`, any overrides (`--problems`, `--langs`, `--reps`,
   `--rep-problems`), the sandbox path and the detected toolchains). Each
   workspace's `.claude/settings.json` confines its agent without naming
   anything it should not know about (Claude Code describes the sandbox's
   rules to the agent):
   - the file tools (Read, Write, Edit) work only inside the session's working
     directories: the workspace, and the session's own transcript directory,
     where Claude Code saves large command outputs for the agent to read. The
     session runs in `acceptEdits` mode with only Bash pre-approved, so any
     other file access needs a permission a headless session cannot grant;
   - shell commands run in Claude Code's OS sandbox, which fails closed and has
     no unsandboxed escape; they may read nothing under the home directory (or
     the sandbox and this checkout, if those lie elsewhere)
     except the workspace, that transcript directory and toolchains installed
     there; they may write only in the workspace and `/tmp`, and have no
     network;
   - Go, Cargo, dub, cabal and Clojure caches and configuration live inside
     the workspace, and shell commands may run for 10 minutes, so slow builds
     don't cost agents extra turns. cabal's only package repository is the
     local one with the test frameworks, so a Haskell project can use the
     packages that ship with GHC and, for tests, those frameworks; the
     clojure CLI has a Maven repository with only Clojure and the
     test-runner in it. git reads no configuration from the home directory,
     which the sandbox hides. The clean
     rebuilds in `finish` use the same configuration, and `JAVA_HOME` is the
     JDK the clojure CLI runs on in both.
2. **`launch DIR`** runs every task as its own `claude -p` session in its
   workspace, six at a time, with a clean environment: no CLAUDE.md files or
   memory, no user settings, plugins or MCP servers, no web tools, no
   auto-update, and the model and effort from the configuration. Each attempt
   is appended to `DIR/runs/<run>/manifest.jsonl` with the session's own
   result (turns, token usage, cost and its final message); the prompts are in
   `DIR/runs/<run>/prompts/`. An attempt that ends in an infrastructure error
   (an API or usage-limit error, a crash) is retried from an empty project
   after a pause; a task that completes is never rerun. A process an agent
   leaves running (a command that outlived its time limit, say) would keep its
   session from exiting, so once the agent has given its final answer and the
   session has been quiet for five minutes, `launch` stops such processes.
   Rerunning `launch` resumes an interrupted run. Progress goes to `DIR/launch.log`.
3. **`finish DIR --dest DEST`** collects the session transcripts and audits
   the run (`tools/audit.py`):
   - integrity findings, which stop the run from being recorded unless given
     `--force`: tool calls naming a forbidden path, a reference implementation
     or a test generator, or another task's project or scratch directory;
     instruction files injected into a session; changed harness files;
   - rule violations, recorded as results: third-party dependencies and
     forbidden standard-library facilities.

   It then verifies every implementation itself: it builds a clean copy of
   the sources with `build.sh` and runs the public tests (and the held-out tests
   of the large problems) on that build, so a project counts as finished only
   if it builds as published. It copies the sources (without build outputs) to
   `DEST/<rep>/<lang>/<slug>/`, and writes `DEST/audit/<run>.json`,
   `DEST/results/<run>.json`, the anonymised transcripts in
   `DEST/transcripts/<run>.tar.gz`, provenance in `DEST/run.json` and one
   prompt per language in `DEST/prompts/`. `--stage` git-adds `DEST`.

   `finish` adds to `DEST`: a later run's projects replace earlier ones of the
   same task, and `run.json` lists every run in order. It copies projects
   over whatever is there, so to replace `implementations/` with a new run,
   empty it first (`git rm -rq implementations`); to redo some tasks, delete
   just their project directories.

`make check` fails if `implementations/` holds a run that is not canonical:
language tips, machine notes or the efficiency note in its prompts, no
`APPROACH.md`, or (for sandboxed runs) an audit that is missing or has
integrity findings.

## Measuring

```
python3 tools/agent_effort.py implementations/transcripts/*.tar.gz --baseline go
./lbench build --tag new --suite all --roots implementations/rep1
./lbench run --tag new
python3 tools/compare.py new --baseline go
```

`make results` rewrites `results/README.md` from `implementations/`
(`tools/results_report.py`), and the unit tests fail while it is out of date.

The headline measure of agent effort is **output tokens**, compared problem
by problem: for each language and problem, the median over repetitions; then
the ratio to the baseline language on the same problem; then the geometric
mean of those ratios, with a 95% bootstrap interval over problems. Turns
(model calls) and cost get the same treatment. Each language also reports how
many of its tasks finished (built from clean and passed their tests). There is
no cap on turns; a task that does not finish counts as at least as costly as
the costliest finished task on its problem, so failing is never cheaper than
finishing. `agent_effort.py` prints these tables and a pooled per-agent
summary with tool calls, context tokens and time (given several runs, in order,
a task a later run repeats is taken from the later run); time depends on API load
and the machine, so it is not used to compare languages.

`python3 tools/code_stats.py implementations` reports code and test lines per
language and the share of each project that is tests. Agents decide how much
to test, so this is a result, not something the prompt controls.

## Configuration

`run-config.json` is the configuration of the committed implementations:

| Key | Value | Meaning |
|---|---|---|
| `langs` | `cpp`, `rust`, `go`, `d`, `python`, `haskell`, `clojure` | Languages |
| `reps`, `repProblems` | 3 on ten problems | Repetitions, on a subset spread across the problem categories, to measure run-to-run noise; every other problem gets one |
| `model` | `claude-sonnet-5-5` | Agent model |
| `effort` | `high` | Agent reasoning effort |
| `concurrency` | 6 | Sessions at once, so builds never queue for cores |
| `approach` | `true` | Point agents at `APPROACH.md` |
| `dc` | `ldc2` | The D compiler in D's build command |
| `out` | `out` | Output directory inside the sandbox |

`args.json` also takes experiment options, off by default: `notes`
(per-language tips), `machineNotes` (per-language toolchain quirks) and
`efficiency` (tell agents efficiency is important). Each makes a run
non-canonical. Use them for experiments, and keep the results out of
`implementations/`.

A full run is 420 tasks (40 problems in seven languages, plus two extra
repetitions of ten problems): roughly 12 hours at a concurrency of 6. On a
Claude plan it may hit usage limits; tasks that do are retried after a pause,
and rerunning `launch` resumes the rest.

## Design choices and limitations

- **One agent.** Everything is written by one model (Sonnet 5.5) in one
  harness (Claude Code), so results describe that agent, not agents in
  general. The runner takes other models unchanged (`model` in
  `run-config.json`).
- **A whole project, not just passing code.** Each task asks for a library,
  a CLI, a README, unit tests and the language's standard build tool, as a
  real project would have. Languages with heavier build systems or project
  layouts pay for that in effort; that is part of what is measured.
- **Toolchain versions.** The toolchains are recent (see `run.json`) and may
  be newer than the model's training data; how much that costs differs by
  language. It is recorded, not corrected for.
- **Language selection.** Seven languages: four widely used compiled or
  scripting languages (C++, Rust, Go, Python), D, and two functional ones
  (Haskell, Clojure), so that the comparison is not only between imperative
  languages. A language with a
  standard-library-only toolchain needs a build line in `tools/runner.py`,
  its toolchain in `detect_toolchains`, and its build directories, source
  files and imports in `tools/impl_run.py`, `tools/code_stats.py` and
  `tools/audit.py`.
- **Environment hints.** Each language's prompt names its toolchain and build
  command; D's names the compiler for `dub test`, Python's says how `run.sh`
  runs without an install step, and Clojure's that the project is a
  `deps.edn` one run by the clojure CLI. These work around the environment
  rather than help with the language.
