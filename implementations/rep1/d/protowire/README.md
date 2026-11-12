# protowire

A Protocol Buffers–style wire codec in D (proto3 semantics). Given a small
message schema it converts between

* the binary **wire format** (varints, tags, packed repeated fields, groups skipped on decode, …),
* **hex** strings, and
* a canonical **text form** such as `{a: 1, b: "x", c: [1, 2], d: {v: -5}}`.

The library is dependency-free (Phobos only); the command-line tool is a thin
layer over it. Decoding is linear in the payload and encoding is linear in the
output, independent of nesting depth (encoding computes all sizes in one pass,
then writes).

## Build

Requires LDC (tested with 1.41.0) and dub (1.40.0).

```sh
./build.sh            # = dub build -b release --compiler=ldc2  -> bin/protowire
dub test --compiler=ldc2   # unit tests
```

## Command-line usage

`protowire` (or `./run.sh`) reads everything from stdin and writes to stdout:

```
<schema>
--
<request>
<request>
...
```

The schema is a list of definitions such as
`message Outer { int32 a = 1; repeated int32 c = 3; Inner d = 4; }` (scalar
types `int32 int64 uint32 uint64 sint32 sint64 bool fixed32 fixed64 sfixed32
sfixed64 string bytes`, message types, and `repeated`). Each request line is

* `decode <Message> <lowercase hex>` → canonical text, or
* `encode <Message> <text>` → canonical lowercase hex (an empty encoding prints an empty line).

A malformed request prints `error`; the exit status is always 0.

```console
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

The full rules (wire format, decode/encode rules, text grammar) are in the
task specification, `problems/protowire/SPEC.md`.

## Library

Add the package to a dub project (`dependency "protowire" path="../protowire"`,
using the `library` configuration) and `import protowire;`.

```d
import protowire;

void main()
{
    auto schema = Schema.parse(`
        message Inner { sint32 v = 1; }
        message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }`);
    auto outer = schema["Outer"];

    // text -> bytes
    ubyte[] bytes = encodeFromText(outer, `{c: [1, 2], a: 1, d: {v: -5}}`);
    assert(toHex(bytes) == "08011a02010222020809");

    // bytes -> text (canonical)
    assert(decodeToText(outer, bytes) == `{a: 1, c: [1, 2], d: {v: -5}}`);

    // bad input throws a ProtowireException subclass
    try decodeToText(outer, [0x08, 0xff]);
    catch (WireException e) { /* truncated varint */ }
}
```

| module | responsibility |
|---|---|
| `protowire.schema` | schema parser, `Schema`, `MessageDescriptor`, `FieldDescriptor`, `FieldKind` |
| `protowire.wire` | varints, tags, zigzag, bounds-checked `Reader`, group skipping |
| `protowire.value` | `Message` / `Slot` value tree |
| `protowire.decoder` | `decodeMessage`: bytes → `Message` |
| `protowire.encoder` | `encodeMessage`: `Message` → canonical bytes |
| `protowire.textformat` | `formatMessage` / `parseMessage`: `Message` ↔ text |
| `protowire.codec` | one-call conversions (`decodeToText`, `encodeFromText`, hex variants) |
| `protowire.request` | the CLI's request-line protocol (`processInput`) |
| `protowire.hex`, `protowire.utf8`, `protowire.errors` | helpers and exception types |

## Layout

```
dub.sdl          manifest ("cli" executable config, "library" config)
source/protowire library (unit tests live beside the code)
app/main.d       command-line tool
build.sh run.sh  build / run scripts
```
