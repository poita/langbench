# Kiln

Kiln is an incremental build system with a deterministic, simulated parallel
scheduler. It reads a *workspace* — build files written in the **Kiln Build
Language** (KBL) plus ordinary source files — evaluates them into a graph of
build steps, and runs the out-of-date steps on `N` simulated workers against an
in-memory file system. Nothing is executed by a real shell: Kiln's sixteen
built-in commands (`write`, `copy`, `concat`, `upper`, `sort_lines`,
`preprocess`, …) are implemented by the engine and each has an integer *cost*
that drives the scheduling simulation.

Change detection is purely content based (FNV-1a 64 hashes recorded in a
`.kiln-state` file), so touching a file never causes a rebuild, an upstream step
that re-runs with identical output stops the chain (early cutoff), and files
discovered by `preprocess` (`@need` directives) are tracked through depfiles.

The specification is `problems/buildsys/SPEC.md` of the surrounding repository;
the design follows `APPROACH.md` (hash-once file system, sorted glob index,
O(log R) ready queue, linear-time commands).

Kiln is pure Python (3.14+) and depends on nothing outside the standard library
(`pytest` is needed only to run the tests).

## Layout

```
pyproject.toml          project manifest (setuptools backend)
build.sh / run.sh       build and run scripts
src/kiln/
    errors.py           KilnError and error constructors
    paths.py            workspace path rules
    hashing.py          FNV-1a 64
    vfs.py              virtual file system, memoised hashes, glob index
    glob.py             glob pattern compiler / matcher
    values.py           KBL value model: total order, equality, wrapping
    lexer.py            comments, logical lines, tokens (shared literal scanner)
    nodes.py            syntax tree
    parser.py           block structure, statements, expression parser
    builtins.py         the 39 built-in functions
    evaluator.py        tree-walking interpreter: scopes, rules, steps
    commands.py         the 16 commands, canonical command strings
    steps.py            Step and its validation
    graph.py            reference resolution, cycle detection, reachability
    state.py            .kiln-state reader/writer and freshness test
    scheduler.py        event-driven worker simulation
    build.py            Builder: one build, configuration through state write
    session.py          session.txt parsing and the session log
    cli.py              command-line front end
tests/                  pytest suite
```

## Building

```sh
./build.sh
```

There is nothing to compile; the script byte-compiles the package (standard
optimisation settings). With the `build` package installed,
`python3 -m build` produces a wheel from `pyproject.toml`, and
`pip install .` installs a `kiln` command.

## Command line

```sh
./run.sh <input directory> <output directory>
# or, without run.sh:
PYTHONPATH=src python3 -m kiln <input directory> <output directory>
```

The input directory holds `session.txt` (the session script), usually a
`main.kiln` root build file, and the initial workspace. Kiln runs the whole
session and writes

* `<output>/log.txt` — one block per session step: a header, the `hit` / `run` /
  `fail` / `cancel` / `remove` events, and a result line;
* `<output>/workspace/…` — every file of the final workspace.

Build errors are ordinary output (`  error E_CYCLE …` in the log); the exit status
is 0 unless the invocation itself is wrong (2) or an internal error occurs (1).

A session script is a sequence of `build [TARGET …] [-j N]`, `create PATH` /
`edit PATH` (content lines up to a line `---`), `delete PATH`, `touch PATH` and
`clean`:

```
build @all -j 4
touch src/a.txt          # no rebuild: change detection is by content
edit src/a.txt
new content
---
build @all -j 4          # only the affected steps run
clean
```

A minimal `main.kiln`:

```
let srcs = glob("src/*.txt")
each s in srcs {
    step {
        out "out/{s}.up"
        in s
        cmd upper()
    }
}
phony all = map(srcs, "out/%.up")
default "@all"
```

## Library

```python
from kiln import Builder, VirtualFS, run_session

fs = VirtualFS()
fs.write(b"main.kiln", b'''
step {
    out "out/hello.txt"
    cmd write("hello\\n")
}
default "out/hello.txt"
''')

builder = Builder(fs)
first = builder.build(workers=2)
print(first.ok, first.ran, first.time)        # True 1 1
for ev in first.events:
    print(ev.kind, ev.start, ev.end, ev.target)  # run 0 1 b'out/hello.txt'

second = builder.build()
print(second.hits)                             # 1  (nothing re-ran)
print(fs.read(b"out/hello.txt"))               # b'hello\n'

# Errors are values, not exceptions:
fs.write(b"main.kiln", b"let x = 1 / 0\n")
print(builder.build().error)                   # E_DIV_ZERO

# Or drive a whole session script and get the log text back:
log = run_session(fs, b"clean\nbuild\n")
```

Public API (`kiln`): `VirtualFS` (`write`, `read`, `delete`, `paths`, `load`,
`dump`), `Builder.build(targets=(), workers=1) -> BuildResult`, `run_session`,
`parse_session`, `parse_file`, `evaluate`, `KilnError`, `fnv1a64`, `hash_hex`.
All file paths and KBL strings are `bytes`.

## Tests

```sh
python3 -m pytest              # from this directory; src/ is on the path
```

The suite covers the lexer and parser (including the `E_PARSE` line-number
rules), glob matching, KBL evaluation and error reporting, the commands, the
scheduler, change detection, the state file and the command-line tool.
