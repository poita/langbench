# tomlcodec

A from-scratch **TOML 1.0.0** parser and canonical serializer in pure Python
(standard library only), with a command-line tool that speaks the
[`toml-test`](https://github.com/toml-lang/toml-test) *tagged JSON* format.

- **Decode**: TOML → compact, key-sorted tagged JSON (or `error` for an invalid document).
- **Encode**: tagged JSON → canonical TOML, such that `decode(encode(x)) == x`.

Scalars are kept as canonical *text* (integers in decimal, floats as 17
significant digits, date-times normalised textually); nothing is round-tripped
through Python numbers or `datetime`, and no TOML library is used.

## Layout

```
src/tomlcodec/
  model.py     Table / Array / Scalar tree
  decoder.py   recursive-descent parser (loads)
  scalars.py   integer, float, bool and date-time literals
  tables.py    header / dotted-key resolution rules
  tagged.py    tagged JSON writer and reader
  encoder.py   canonical TOML writer (dumps)
  cli.py       command-line front end
tests/         pytest suite
build.sh run.sh
```

## Build

There is no install step. `./build.sh` byte-compiles the package (and so
doubles as a syntax check). Python 3.12+ is required; the project is developed
on 3.14.

## Command line

`./run.sh` (or `PYTHONPATH=src python3 -m tomlcodec`) reads stdin: a first line
`decode` or `encode`, then the document verbatim.

```console
$ printf 'decode\nname = "Tom"\nport = 0x1F\n' | ./run.sh
{"name":{"type":"string","value":"Tom"},"port":{"type":"integer","value":"31"}}

$ printf 'decode\na = 01\n' | ./run.sh
error

$ printf 'encode\n{"a":{"type":"integer","value":"1"},"t":{"b":{"type":"bool","value":"true"}}}\n' | ./run.sh
a = 1

[t]
b = true
```

Output is UTF-8 ending in one newline; the exit status is 0 (2 for a bad mode
line or arguments). Decode prints `error` for any invalid document, including
invalid UTF-8, a BOM, a lone CR, or a redefined table.

## Library

```python
import tomlcodec

doc = tomlcodec.loads("""
title = "Example"
[owner]
dob = 1979-05-27 07:32:00Z
""")

doc["owner"]["dob"]            # Scalar('datetime', '1979-05-27T07:32:00Z')
tomlcodec.to_tagged_json(doc)  # compact key-sorted tagged JSON
tomlcodec.dumps(doc)           # canonical TOML text

tomlcodec.decode(b'a = 1')     # TOML -> tagged JSON in one call
tomlcodec.encode('{"a":{"type":"integer","value":"1"}}')  # and back

try:
    tomlcodec.loads("a = 01")
except tomlcodec.TomlDecodeError as e:
    print(e.msg, e.line, e.column)
```

Public names: `loads`, `dumps`, `to_tagged_json`, `from_tagged_json`, `decode`,
`encode`, the node types `Table` (a read-only `Mapping`), `Array` (a
`Sequence`) and `Scalar` (`.type`, `.text`), and the errors `TomlDecodeError`
and `TaggedJsonError`. Parsing recurses per nesting level, so very deeply
nested documents need a raised `sys.setrecursionlimit` (the CLI sets one);
beyond the limit `loads` raises `TomlDecodeError`.

## Tests

```
python3 -m pytest                       # from this directory
cd .. && python3 run_tests.py toml -- toml/run.sh   # shared corpus via the CLI
```

`tests/test_corpus.py` also replays the shared corpus in
`../problems/toml/tests` when it exists.
