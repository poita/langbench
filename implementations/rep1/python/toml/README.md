# tomlcodec

A from-scratch **TOML 1.0.0** parser and canonical serializer in pure Python
(standard library only — no `tomllib`, no third-party TOML code), with a small
command-line tool that speaks the [`toml-test`](https://github.com/toml-lang/toml-test)
*tagged JSON* interchange format.

* `loads` parses a document into a tree and rejects every invalid TOML 1.0.0 document.
* `dumps` writes a tree back as canonical TOML (`decode(encode(x)) == x`).
* Linear-time: every scan is bounded by the current token or line.

## Build

No install step is needed; `build.sh` just byte-compiles the sources.

```sh
./build.sh
```

Run the tests (needs `pytest`):

```sh
python3 -m pytest
```

The project is a standard `pyproject.toml` / `src` layout, so `pip install .`
also works and provides a `tomlcodec` console script.

## Command line

`run.sh` reads stdin: the first line is the mode (`decode` or `encode`), the rest is the document.

```sh
printf 'decode\nname = "Tom"\nports = [8001, 8002]\n' | ./run.sh
# {"name":{"type":"string","value":"Tom"},"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]}

printf 'encode\n{"a":{"type":"integer","value":"1"}}' | ./run.sh
# a = 1
```

* `decode` prints compact, key-sorted tagged JSON, or the single word `error`
  if the input is not valid TOML 1.0.0 (floats are printed as `%.16e`; date-times
  are canonicalised textually).
* `encode` prints canonical TOML: plain values first, then sub-tables and
  arrays of tables in key order, each with a header.
* The exit status is 0 in both cases.

## Library

```python
import tomlcodec

doc = tomlcodec.loads(b"""
title = "Example"
[owner]
dob = 1979-05-27T07:32:00-08:00
[[fruit]]
name = "apple"
""")

doc["title"]                     # Scalar(type='string', text='Example')
tomlcodec.to_python(doc)         # plain dicts / lists / str / int / float / datetime ...
tomlcodec.to_tagged_json(doc)    # '{"fruit":[{"name":{"type":"string","value":"apple"}}],...}'
print(tomlcodec.dumps(doc))      # canonical TOML

tree = tomlcodec.from_tagged_json('{"x":{"type":"bool","value":"true"}}')
tomlcodec.dumps(tree)            # 'x = true\n'

try:
    tomlcodec.loads("a = 01")
except tomlcodec.TomlDecodeError as exc:
    print(exc.lineno, exc.colno, exc.msg)
```

### Public API

| name | purpose |
|------|---------|
| `loads(data)` | parse `bytes` (UTF-8) or `str` into a `Table`; raises `TomlDecodeError` |
| `dumps(tree)` | canonical TOML text for a tree |
| `to_tagged_json(tree)` / `from_tagged_json(text)` | tagged-JSON interchange |
| `to_python(tree)` | convert to native Python objects |
| `Table`, `ArrayOfTables`, `Scalar` | tree node types; scalars keep their canonical *text* |
| `TomlError`, `TomlDecodeError`, `TaggedJSONError` | exceptions |

### Layout

| module | responsibility |
|--------|----------------|
| `parser.py` | recursive-descent decoder and table-definition rules |
| `strings.py` | the four string forms and their escapes |
| `numeric.py` | integer/float parsing and canonical float formatting |
| `datetimes.py` | date/time validation and canonical text |
| `model.py` | `Table`, `ArrayOfTables`, `Scalar` |
| `tagged.py` | tagged-JSON reader and writer |
| `encoder.py` | canonical TOML writer |
| `convert.py` | `to_python` |
| `cli.py`, `__main__.py` | command-line tool |

## Notes

Deeply nested documents recurse in the parser; the CLI raises Python's
recursion limit for this. Library callers who parse very deep documents may
need to do the same (otherwise `TomlDecodeError` is raised).
