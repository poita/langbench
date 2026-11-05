# protowire

A small D library and command-line tool for the Protocol Buffers (proto3) wire
format. Given a message schema, it decodes binary messages to a canonical text
form and encodes that text form back to canonical (deterministic) bytes. It is
standard-library only (Phobos/druntime) and implements the wire format itself.

* **Library** (`source/protowire/`): schema parser, decoder, encoder, text
  renderer and parser, split by responsibility.
* **CLI** (`cli/main.d`): a thin wrapper that reads a schema plus a list of
  `decode`/`encode` requests on stdin and prints one result line per request.
* **Tests** (`tests/`): unit tests, kept apart from the library sources.

## Building

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh                 # = dub build -b release --compiler=ldc2 --config=cli
./run.sh < input.txt       # runs bin/protowire
dub test --compiler=ldc2   # unit tests
```

## Command-line use

Standard input is a schema, a line consisting of `--`, then requests, one per
line:

```
message Inner { sint32 v = 1; }
message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }
--
encode Outer {a: 1, b: "x", c: [1, 2], d: {v: -5}}
decode Outer 08011201781a02010222020809
decode Outer 08ff
```

Each request produces one output line (`error` for a malformed request; the
exit code is always 0):

```
08011201781a02010222020809
{a: 1, b: "x", c: [1, 2], d: {v: -5}}
error
```

* `decode <Message> <lowercase-hex>` prints the canonical text form.
* `encode <Message> <text>` prints the lowercase hex of the canonical encoding
  (an empty line if the encoding is empty).

Schema language: `message Name { [repeated] type name = number; ... }` where
`type` is one of `int32 int64 uint32 uint64 sint32 sint64 bool fixed32 fixed64
sfixed32 sfixed64 string bytes` or a message name (forward and recursive
references allowed). Supported semantics follow proto3: repeated numeric fields
are packed on encode and accepted packed or unpacked on decode, unknown fields
and groups are skipped, repeated occurrences of a singular message are merged.

## Library example

```d
import protowire;

void main()
{
    auto schema = Schema.parse(`
        message Inner { sint32 v = 1; }
        message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }
    `);
    auto codec = new Codec(schema);

    // text -> bytes
    ubyte[] wire = codec.encode("Outer", `{a: 1, b: "x", c: [1, 2], d: {v: -5}}`);
    assert(wire == [0x08, 0x01, 0x12, 0x01, 0x78, 0x1a, 0x02, 0x01, 0x02, 0x22, 0x02, 0x08, 0x09]);

    // bytes -> text
    assert(codec.decode("Outer", wire) == `{a: 1, b: "x", c: [1, 2], d: {v: -5}}`);

    // Malformed input throws CodecException.
    try
        codec.decode("Outer", [0x08, 0xff]);
    catch (CodecException e)
        assert(e.msg.length);
}
```

For allocation-free use there is a lower-level API:
`Codec.decodeToText(messageIndex, bytes, ref ByteBuffer)` and
`Codec.encodeFromText(messageIndex, text, ref ByteBuffer)` return `false` on
malformed input (with `Codec.lastError` describing it) and leave the buffer
unchanged. `processDocument` implements the whole CLI protocol over a byte
slice.

## Layout

| Module | Responsibility |
|---|---|
| `protowire.schema` | schema parser and compiled message descriptors |
| `protowire.wire` | varints, zigzag, wire types |
| `protowire.decoder` | wire bytes to value tree |
| `protowire.render` | value tree to canonical text |
| `protowire.textparser` | canonical text to value tree |
| `protowire.encoder` | value tree to wire bytes (size pass, then write pass) |
| `protowire.codec` | `Codec`: the public decode/encode façade |
| `protowire.session` | the line-oriented request protocol used by the CLI |
| `protowire.value`, `protowire.memory` | value tree, arena allocator, byte buffer |
| `protowire.hex`, `protowire.utf8` | hex conversion and strict UTF-8 validation |

Design notes: the schema is compiled once (fields sorted by number, binary
search by number and hash lookup by name); each request builds its value tree
in a reusable arena; the encoder computes sizes bottom-up once and then writes
every byte exactly once; all output goes into one buffer written at the end.
