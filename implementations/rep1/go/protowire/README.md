# protowire

A small, dependency-free Go library and command-line tool that converts between
Protocol Buffers wire-format bytes (proto3 semantics) and a canonical text form,
driven by a tiny text schema. Standard library only.

* **decode**: hex-encoded bytes → canonical text, e.g. `{a: 1, c: [1, 2]}`
* **encode**: text → canonical (deterministic, minimal) hex-encoded bytes

It handles varints, zigzag, fixed-width types, packed and unpacked repeated
fields, recursive message types, merging of repeated sub-messages, skipping of
unknown fields and groups, UTF-8 validation, and the strict limits on tag,
varint and length-prefix sizes. Malformed input is reported as an error, never
a panic.

## Layout

| package            | responsibility                                                |
|--------------------|---------------------------------------------------------------|
| `protowire`        | convenience facade (`ParseSchema`, `NewCodec`, `Process`)     |
| `protowire/wire`   | varints, zigzag, fixed ints, tags, strict lowercase hex       |
| `protowire/schema` | schema language parser and compiled message types             |
| `protowire/codec`  | decoder, text renderer, text parser, two-pass encoder         |
| `protowire/batch`  | the line-oriented request protocol used by the CLI            |
| `cmd/protowire`    | the command-line tool                                         |

Design notes: the schema is compiled once into per-message field arrays sorted
by number (binary-search lookup by number, map lookup by name). Decoding builds
a compact value tree (one slot per schema field, lists allocated on first use,
strings kept as offsets into the input buffer), decoding sub-messages in place
from the same buffer. Encoding parses text into the same tree, computes every
message size bottom-up once (cached on the node), and then writes the bytes
forward in a single pass, so no sub-message is ever copied or re-sized.

## Build

Requires Go 1.27 or newer.

```sh
./build.sh          # builds bin/protowire
go test ./...       # unit tests
```

`build.sh` and `run.sh` work from any directory; `run.sh` executes
`bin/protowire`.

## Command-line usage

The tool reads everything from stdin and writes one line per request to stdout.

```
<schema>
--
decode <Message> <hex>
encode <Message> <text>
...
```

```sh
$ ./run.sh <<'EOF'
message Inner { sint32 v = 1; }
message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }
--
encode Outer {a: 1, b: "x", c: [1, 2], d: {v: -5}}
decode Outer 08011201781a02010222020809
decode Outer 08ff
EOF
08011201781a02010222020809
{a: 1, b: "x", c: [1, 2], d: {v: -5}}
error
```

The schema is a list of `message Name { [repeated] type name = number; ... }`
definitions; types are the proto3 scalars (`int32 int64 uint32 uint64 sint32
sint64 bool fixed32 fixed64 sfixed32 sfixed64 string bytes`) or message names
(forward and recursive references allowed). A malformed request prints `error`;
the exit status is 0 unless the schema itself cannot be parsed or I/O fails
(exit 1, diagnostic on stderr).

## Library usage

```go
package main

import (
	"fmt"

	"protowire"
)

func main() {
	sch, err := protowire.ParseSchema(`
		message Point { sint32 x = 1; sint32 y = 2; }
		message Path  { string name = 1; repeated Point points = 2; }`)
	if err != nil {
		panic(err)
	}
	c := protowire.NewCodec(sch) // not safe for concurrent use; one per goroutine

	wire, err := c.Encode("Path", `{name: "walk", points: [{x: 1, y: -1}, {y: 2}]}`)
	if err != nil {
		panic(err)
	}
	fmt.Printf("%x\n", wire) // 0a0477616c6b12040802100112021004

	text, err := c.Decode("Path", wire)
	fmt.Println(text, err) // {name: "walk", points: [{x: 1, y: -1}, {y: 2}]} <nil>
}
```

For allocation-conscious callers, `codec.Codec.AppendDecode` and `AppendEncode`
append to a caller-supplied buffer and take a `*schema.MessageType`.
