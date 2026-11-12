# protowire

A small Haskell library and command-line tool for a Protocol Buffers-style
wire codec (proto3 semantics). Given a message schema it

- **decodes** hex-encoded wire bytes into a canonical text form, and
- **encodes** that text form back into hex-encoded wire bytes.

It has no dependencies beyond GHC's bundled `base`, `bytestring` and
`containers`; the wire format, UTF-8 validation, hex and text syntax are all
implemented here.

## Building

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh          # cabal build, then copies the CLI to bin/protowire
cabal test          # unit tests (hspec) and properties (QuickCheck)
```

`./run.sh` runs the built CLI from any directory.

## Command-line usage

The CLI reads everything from stdin and writes to stdout. The input is a
schema, a line consisting of `--`, and then one request per line:

```
message Inner { sint32 v = 1; }
message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }
--
encode Outer {a: 1, b: "x", c: [1, 2], d: {v: -5}}
decode Outer 08011201781a02010222020809
decode Outer 08ff
```

```sh
./run.sh < input.txt
```

prints one line per request:

```
08011201781a02010222020809
{a: 1, b: "x", c: [1, 2], d: {v: -5}}
error
```

A request that is malformed in any way (bad hex, truncated wire data, invalid
text, out-of-range numbers, ...) prints `error`; the exit status is still 0.
Exit status 1 is reserved for a schema that does not parse.

### Schema syntax

```
message <Name> { [repeated] <type> <name> = <number>; ... }
```

`<type>` is `int32 int64 uint32 uint64 sint32 sint64 bool fixed32 fixed64
sfixed32 sfixed64 string bytes` or the name of any message in the schema
(forward and recursive references are fine). Whitespace is insignificant.

### Semantics in brief

- **Decode**: unknown fields and fields with the wrong wire type are skipped
  (groups too); later scalars win; repeated fields append, packed or
  unpacked; repeated occurrences of a singular message field are merged.
  Varints are at most 10 bytes, tags and length prefixes at most 5; strings
  must be valid UTF-8. Output is canonical: fields in field-number order,
  defaults omitted, `d: {}` kept for present sub-messages.
- **Encode**: fields in field-number order, defaults omitted, repeated numeric
  fields packed, minimal varints. Text may use any spacing and field order,
  explicit defaults, and `\" \\ \n \r \t \xHH` string escapes; bytes are
  written `x"00ff"`. Integers must be in range for their type.

## Library

The library is organised by responsibility:

| module | role |
| --- | --- |
| `Protowire` | re-exports the everyday API |
| `Protowire.Schema` | schema parser and descriptors |
| `Protowire.Value` | the `Message` / `Value` tree |
| `Protowire.Wire` | varints, tags, length prefixes, skipping, zigzag |
| `Protowire.Decode` | wire bytes → `Message` |
| `Protowire.Encode` | `Message` → wire bytes (one pass, no re-encoding) |
| `Protowire.Text.Parse` / `Protowire.Text.Render` | text form ↔ `Message` |
| `Protowire.Hex`, `Protowire.Utf8` | hex and strict UTF-8 |
| `Protowire.Request` | the line protocol used by the CLI |

```haskell
{-# LANGUAGE OverloadedStrings #-}
import qualified Data.ByteString.Lazy as BL
import Protowire

main :: IO ()
main = do
  let Right schema = parseSchema "message M { int32 a = 1; repeated string s = 2; }"
      Just m       = lookupMessage "M" schema

  -- text -> wire bytes
  let Right msg   = parseText m "{s: [\"hi\"], a: 150}"
      Right bytes = encode m msg                 -- 08 96 01 12 02 68 69

  -- wire bytes -> text
  let Right msg'  = decode m (BL.toStrict bytes)
  BL.putStr (renderText m msg')                  -- {a: 150, s: ["hi"]}
```

Errors are values: `decode` returns `Either WireError Message`, `parseText`
returns `Either TextError Message` (with a byte offset), and `encode` returns
`Either EncodeError ...` if a hand-built `Message` does not fit the schema.

## Performance

Decoding reads each byte once and skips unknown fields and groups without
decoding them. Encoding computes every sub-message's length as it builds it,
so nothing is encoded twice regardless of nesting depth, and hex/text output
is produced with `Builder`s. Whole runs are linear in input plus output size.
