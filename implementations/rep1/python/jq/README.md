# jqlite

`jqlite` is an interpreter for a subset of the [jq](https://jqlang.github.io/jq/)
filter language (semantics of jq 1.7, `jq -c`), written in pure Python with no
dependencies. It includes its own JSON parser and serializer, a recursive-descent
filter parser and a lazy, generator-based tree-walking evaluator.

Supported: paths (`.a`, `.[k]`, `.[]`, `.[a:b]`, `?`), pipes and commas, arithmetic,
comparison, `and`/`or`, `if`/`elif`/`else`, `as` bindings, `reduce`, array and object
construction, and the builtins `empty error not length keys has type add select map
sort sort_by group_by unique reverse min max tostring tonumber`.

## Layout

```
src/jqlite/
  errors.py   exception types
  values.py   data model: Obj, ordering (sort_key), equality, truthiness
  jsonio.py   JSON parser (loads) and compact serializer (dumps)
  ops.py      arithmetic, comparison, indexing and slicing primitives
  lexer.py    filter tokenizer
  parser.py   recursive-descent parser -> tuple syntax tree
  interp.py   compiles the tree to closures; lazy generator evaluation
  builtins.py builtin functions
  cli.py      command-line tool
tests/        pytest suite
```

## Build

Requires Python 3.14. There is nothing to install; `./build.sh` byte-compiles the
sources (`python3 -m compileall`). `pyproject.toml` describes the package for
`pip install .` if you want a `jqlite` command.

## Command line

```
$ printf '.users | map(.age) | add\n{"users":[{"age":31},{"age":45}]}' | ./run.sh
76
```

Line 1 of stdin is the filter; the rest is one JSON document. Each result is printed
as a line of compact JSON. If evaluation fails, the results before the failure are
printed, followed by a line `error`, and the exit status is still 0. Malformed
filters or documents are reported on stderr with exit status 2.

## Library

```python
import jqlite

f = jqlite.compile('.items | map(select(.qty > 1) | {name, total: (.qty * .price)})')
doc = jqlite.loads('{"items":[{"name":"a","qty":2,"price":1.5},{"name":"b","qty":1,"price":9}]}')

for result in f.run(doc):          # lazy; raises jqlite.JQError where jq would fail
    print(jqlite.dumps(result))    # {"name":"a","total":3}

list(jqlite.run('.[] | . * 2', '[1, 2]'))   # [2.0, 4.0]
```

Public names: `compile`, `Filter` (`run`, `run_text`), `run`, `loads`, `dumps`, `Obj`,
`from_python`, `to_python`, `sort_key`, `JQError`, `JQSyntaxError`, `JSONDecodeError`.
Values are `None`, `bool`, `float`, `str`, `list` and `Obj` (an insertion-ordered
`dict`); they are never mutated.

## Design notes

* Values are shared, never copied; `+`/`*` on objects and arrays build new values.
* Each filter node compiles to a closure returning an iterable of outputs; nodes that
  always yield exactly one value also get a "direct" closure that skips generator
  overhead.
* `Obj` caches its sorted key list; sorting uses one precomputed key per element
  (`sort_key`) and Python's stable sort.

## Tests

```
python3 -m pytest
```
