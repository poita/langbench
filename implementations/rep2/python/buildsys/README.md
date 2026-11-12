# Kiln

Kiln is an incremental build system. It reads a *workspace* — build files written in
the **Kiln Build Language** (KBL) plus ordinary source files — evaluates the build
files into a graph of steps, and runs the steps that are out of date on a simulated
set of parallel workers against an in-memory file system. Nothing is ever executed by
a real shell: Kiln's sixteen built-in commands are implemented by the engine, and each
command has an integer *cost* that drives a fully deterministic scheduling simulation.

A whole *session* — a scripted sequence of builds and workspace edits — is driven from
a `session.txt`, and produces a log of everything that happened plus the final state of
the workspace.

Pure standard-library Python (3.12+; developed on 3.14); `pytest` is needed only for the tests.

## Building

There is no compile step. `build.sh` byte-compiles the package (catching syntax errors early):

```sh
./build.sh
```

For a regular installable distribution the project is a standard `pyproject.toml`
(setuptools backend, `src/` layout):

```sh
python3 -m pip install .        # installs the `kiln` console script and the `kiln` package
```

## Command line

```
kiln <input directory> <output directory>
```

or, without installing, `./run.sh <input directory> <output directory>`
(equivalent to `PYTHONPATH=src python3 -m kiln …`).

The input directory holds `session.txt` and the initial workspace (`main.kiln`, sources,
and optionally `out/…` and `.kiln-state`). The program writes only into the output
directory:

```
<output>/log.txt             the session log
<output>/workspace/<path>    every file of the final workspace
```

A build error is normal output (it appears in `log.txt`), so the exit status is 0 for
every well-formed session; a wrong argument count exits 2.

A session is a list of steps — `build [TARGET ...] [-j N]`, `create PATH` / `edit PATH`
followed by content lines and `---`, `delete PATH`, `touch PATH`, and `clean`:

```
build @all -j 4
edit src/a.txt
line one
---
build @all -j 2
clean
```

and a build file looks like this:

```
let names = ["alpha", "beta", "gamma"]
each i, n in names {
    step {
        out "out/{n}.txt"
        cmd write("{i}:{n}\n")
    }
}
step {
    out "out/index.txt"
    in map(names, "out/%.txt")
    cmd concat()
}
phony all = ["out/index.txt"]
default "@all"
```

## Library

Everything the CLI does is available as a library (`src/kiln`):

```python
from kiln import VirtualFS, build, run_session

fs = VirtualFS({
    b"main.kiln": b'''
step {
    out "out/shout.txt"
    in "src/hi.txt"
    cmd upper()
}
default "out/shout.txt"
''',
    b"src/hi.txt": b"hello\n",
})

result = build(fs, jobs=2)            # a BuildResult
assert result.ok and result.ran == 1
print(fs.read(b"out/shout.txt"))      # b'HELLO\n'

again = build(fs, jobs=2)             # nothing changed: a cache hit
assert (again.ran, again.hits) == (0, 1)

fs.write(b"src/hi.txt", b"bye\n")     # content-based change detection
assert build(fs).ran == 1

log = run_session(fs, b"clean\nbuild\n")   # whole sessions return the log text (bytes)
```

Paths and file contents are `bytes` throughout (KBL strings are byte strings).
Errors are reported as `result.error`, a `KilnError` with a `kind` (e.g. `E_CYCLE`) and a
`detail`; configuration errors leave the workspace untouched.

### Modules

| Module | Responsibility |
|--------|----------------|
| `kiln.lexer` | comment stripping, logical lines, tokens (one shared literal scanner) |
| `kiln.parser`, `kiln.nodes` | statements/expressions to syntax trees; which `E_PARSE` is reported |
| `kiln.values` | the four value types, total order, deep equality |
| `kiln.builtins`, `kiln.globs` | the 39 built-in functions; glob compile and match |
| `kiln.evaluator` | tree-walking interpreter over a chain of scopes; `include`, rules |
| `kiln.steps`, `kiln.commands` | step validation; the sixteen commands and canonical command strings |
| `kiln.graph` | reference resolution, whole-graph validation, cycle detection, reachability |
| `kiln.state` | the `.kiln-state` reader/writer and the freshness decision |
| `kiln.scheduler` | the event-driven worker simulation (heap-based ready sets) |
| `kiln.build`, `kiln.session`, `kiln.cli` | one build; session scripts and the log; the command line |
| `kiln.vfs`, `kiln.hashing`, `kiln.paths`, `kiln.errors` | virtual file system, FNV-1a-64, path syntax, error types |

## Design notes

* Each distinct file content is hashed once (per-path hash cache invalidated on write,
  plus a bounded content memo); freshness checks and state lines reuse it.
* Every build re-lexes, re-parses and re-evaluates the build files; only the file
  system, its hashes and a sorted glob index persist between builds.
* `glob` binary-searches the sorted index of eligible paths for the pattern's
  wildcard-free prefix, then matches only those candidates.
* Lists are never mutated after creation, so copying one is O(1); `a ++ b` is O(|a|+|b|).
* The ready sets of the scheduler are heaps keyed by step serial number — O(log R) per operation.
* Commands are linear in their bytes; `sort_lines` sorts, `dedup`/`preprocess` use sets.

## Tests

```sh
python3 -m pytest          # from this directory; needs only pytest
```

The suite covers hashing and paths, the glob matcher, the lexer/parser (including which
`E_PARSE` wins), expressions and built-ins, every error kind reachable from KBL, the
commands, the state file, change detection, the scheduler, the specification's worked
examples end to end, and the command-line contract.
