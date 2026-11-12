# protowire

A small, dependency-free Python library and command-line tool for the
Protocol Buffers wire format (proto3 semantics). Given a message schema it
decodes hex-encoded bytes into a canonical text form and encodes that text
form back into hex.

## Requirements and build

Python 3.14+ and nothing else (pytest only for the tests). There is nothing
to compile: `./build.sh` byte-compiles the sources as a syntax check.

```
./build.sh
```

## Command-line use

`./run.sh` (equivalently `PYTHONPATH=src python3 -m protowire`) reads all of
stdin and writes one output line per request:

```
<schema>
--
decode <Name> <hex>
encode <Name> <text>
```

The schema is a list of `message Name { [repeated] type name = N; ... }`
definitions (scalar types, nested/recursive messages, `repeated`). A malformed
request prints `error`; the exit status is 0.

```
$ ./run.sh <<'IN'
message Inner { sint32 v = 1; }
message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }
--
encode Outer {a: 1, b: "x", c: [1, 2], d: {v: -5}}
decode Outer 08011201781a02010222020809
decode Outer 08ff
IN
08011201781a02010222020809
{a: 1, b: "x", c: [1, 2], d: {v: -5}}
error
```

## Library use

```python
from protowire import parse_schema, decode, encode, ProtowireError

schema = parse_schema("""
    message Inner { sint32 v = 1; }
    message Outer { int32 a = 1; repeated string tags = 2; Inner d = 3; }
""")

data = encode(schema, "Outer", '{a: 1, tags: ["x", "y"], d: {v: -5}}')  # bytes
print(decode(schema, "Outer", data))   # {a: 1, tags: ["x", "y"], d: {v: -5}}

try:
    decode(schema, "Outer", b"\x08\xff")
except ProtowireError as exc:
    print("bad input:", exc)
```

Public API (`protowire`):

| name | purpose |
|---|---|
| `parse_schema(text) -> Schema` | parse a schema; raises `SchemaError` |
| `decode(schema, name, data) -> str` | wire bytes to canonical text |
| `encode(schema, name, text) -> bytes` | text form to canonical wire bytes |
| `decode_message`, `encode_message` | the same, on `Message` value trees |
| `parse_text`, `format_message` | text form to/from `Message` trees |
| `ProtowireError`, `SchemaError` | errors for bad data / bad schema |

## Layout

| module | responsibility |
|---|---|
| `scalars` | scalar types: wire type, conversions, ranges |
| `schema` | descriptors and the schema parser |
| `values` | `Message`, the value tree |
| `wire` | varints, tags, lengths, field/group skipping |
| `decoder` / `encoder` | wire bytes to/from the value tree |
| `textfmt` / `textparse` | canonical text rendering / lenient text parsing |
| `requests` / `cli` | the stdin request protocol and the command |

Decoding reads each byte once and skips unknown fields without interpreting
them. Encoding is two-pass (sizes, then one write into a single buffer), so
it is linear in the output regardless of nesting depth.

## Tests

```
PYTHONPATH=src python3 -m pytest
```
