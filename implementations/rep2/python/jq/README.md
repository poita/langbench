# jqlite

A pure-Python interpreter for a subset of the [jq](https://jqlang.github.io/jq/)
filter language (jq 1.7 semantics, `jq -c` output). It has a small reusable
library, a thin command-line tool on top, and no dependencies beyond the Python
standard library. The JSON parser, the JSON writer and the filter interpreter are
all written from scratch (no `json` module).

Supported: paths (`.a`, `."a b"`, `.[k]`, `.[]`, `.[a:b]`, with `?`), pipes, comma,
arithmetic, comparisons, `and`/`or`, `if`/`elif`/`else`, `as $x` bindings,
`reduce`, array/object construction, `try` via `?`, and the builtins `empty error
not length keys has type add select map sort sort_by group_by unique reverse min
max tostring tonumber`. See `problems/jq/SPEC.md` for the exact semantics.

## Layout

```
src/jqlite/
  __init__.py   public API (Filter, compile_filter, run, loads, dumps, ...)
  jsonio.py     JSON parser (iterative, regex-scanned) and compact serializer
  values.py     data model, jq's total ordering (sort_key), Obj
  lexer.py / parser.py / ast.py   filter text -> syntax tree
  compiler.py   syntax tree -> closures (generators, with a single-output fast path)
  builtins.py   builtin functions
  ops.py        arithmetic, comparison, indexing, slicing
  cli.py        command-line front end
tests/          pytest suite
build.sh run.sh
```

## Build

```
./build.sh        # byte-compiles src/ (pure Python; nothing else to build)
```

Requires Python 3.12+ (developed on 3.14). `pip install -e .` also works via
`pyproject.toml` and provides a `jqlite` command.

## Command line

`run.sh` reads **stdin**: the first line is the filter, everything after is one JSON
document. Each result is printed as compact JSON on its own line. If an
uncaught runtime error occurs, the results produced before it are printed, then the line
`error`, and evaluation stops. The exit status is 0 (2 for a malformed filter or
document).

```
$ printf '%s\n%s' '.users | map(select(.age >= 30)) | sort_by(.age) | map(.name)' \
    '{"users":[{"name":"ann","age":31},{"name":"bob","age":25}]}' | ./run.sh
["ann"]
```

Very deeply nested filters recurse deeply; the CLI runs on a large-stack thread with
a raised recursion limit for that reason.

## Library

```python
import jqlite

flt = jqlite.compile_filter("[.[] | select(.age >= 30) | .name]")   # raises JQSyntaxError if invalid
doc = jqlite.loads('[{"name": "ann", "age": 31}, {"name": "bob", "age": 25}]')

for result in flt.run(doc):               # lazy; raises JQError at an uncaught runtime error
    print(jqlite.dumps(result))           # ["ann"]

flt.all(doc)                              # -> [['ann']]
jqlite.run(".a + 1", jqlite.from_native({"a": 1}))   # -> [2.0]
jqlite.to_native(jqlite.run(".a + 1", jqlite.from_native({"a": 1}))[0])   # -> 2
```

Values are `None`, `bool`, `float`, `str`, `list` and `jqlite.Obj` (an
insertion-ordered `dict`). They are treated as immutable and shared, never copied.
Use `from_native` / `to_native` to convert plain Python data. For filters nested hundreds
of levels deep, raise `sys.setrecursionlimit` before compiling them.

## Design notes

* Filters are compiled once to nested closures. Each node returns an iterable
  of outputs, so evaluation is lazy and errors surface at the point they occur.
  Nodes statically known to produce one output also expose a direct
  `single(input, env)` function, which avoids generator overhead.
* Variables live in a persistent linked environment.
* Sorting keys map values to tuples whose native ordering is jq's order, so `sort`,
  `sort_by`, `group_by`, `unique`, `min`, `max` and comparisons use Python's stable
  O(n log n) sort with one key evaluation per element. An object's sorted keys are
  computed at most once.
* `add` is linear in the total size of its elements.

## Tests

```
python3 -m pytest          # from this directory; needs pytest
```

The repository-level suite is run with `python3 run_tests.py jq -- jq/run.sh`
from the directory above.
