# jsoncanon

A strict RFC 8259 JSON parser and **canonical serializer**, written from
scratch in pure Python (standard library only; no `json` module).

The canonical form has no insignificant whitespace, duplicate object keys
resolved (last wins), members sorted by UTF-16 code units, minimal string
escaping, and numbers echoed textually (never converted to floats) with
normalised exponents. Documents are checked strictly: valid UTF-8 only, no BOM,
ASCII-only whitespace/digits, correct surrogate pairs, and nesting depth at
most 512.

## Build

```sh
./build.sh          # byte-compiles src/ (python3 -m compileall)
```

There is no install step. For a regular install use `pip install .`
(`pyproject.toml`, setuptools backend); `pip install .[test]` adds pytest.

## Command line

`run.sh` reads one document from stdin and prints a single line: the
canonical form, or `invalid`. The exit status is 0 either way.

```sh
$ echo '{ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null }' | ./run.sh
{"a":"héllo/","b":null}
$ echo '[1, 2, ]' | ./run.sh
invalid
```

Equivalent: `PYTHONPATH=src python3 -m jsoncanon`.

## Library

```python
from jsoncanon import canonicalize, parse, dumps, JSONError, Number, Object

canonicalize(b'{"b":1e+05,"a":[true,null]}')   # b'{"a":[true,null],"b":1e5}'

try:
    tree = parse(b'{"x": [1, 2.50]}')          # Object([("x", [Number('1'), Number('2.50')])])
except JSONError as exc:
    print("invalid:", exc)
else:
    print(dumps(tree))                          # {"x":[1,2.50]}
```

Public API (`jsoncanon`):

| Name | Purpose |
|------|---------|
| `parse(data)` / `loads` | bytes (or str) → tree; raises `JSONError` |
| `dumps(tree)` / `dump(tree)` | tree → canonical `str` / `bytes` (no newline) |
| `canonicalize(data)` | bytes → canonical bytes |
| `Number`, `Object` | node types (`Number` is a `str` of canonical text; `Object.members` keeps duplicates in input order) |
| `JSONError` | invalid document (`ValueError` subclass) |
| `MAX_DEPTH` | 512 |

Modules: `parser` (UTF-8 validation + iterative single-pass parser),
`serializer` (iterative canonical writer), `values`, `errors`, `cli`.
Parsing and serialisation use explicit stacks, so depth never hits Python's
recursion limit, and output is built in one fragment list (O(n)).

## Tests

```sh
python3 -m pytest        # from this directory
```
