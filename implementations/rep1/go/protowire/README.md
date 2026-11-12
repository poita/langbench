# protowire

A small, dependency-free Go library and command-line tool for the Protocol
Buffers (proto3) wire format, driven by a schema supplied at run time rather
than by generated code.

- Decode wire bytes (as hex) into a canonical text form, and encode that text
  form back into canonical wire bytes.
- Proto3 semantics: unknown fields, wrongly-typed fields and groups are
  skipped; repeated numeric fields accept packed and unpacked data; repeated
  occurrences of a singular message field are merged.
- Linear time: decode is O(payload + output), encode is O(text + output),
  independent of nesting depth.
- Standard library only.

Requires Go 1.27.1.

## Build

```sh
./build.sh          # builds bin/protowire
go test ./...       # runs the unit tests
```

`run.sh` runs the built binary from any directory (`./run.sh < input`).

## Command-line usage

`protowire` reads everything from stdin and writes one line per request to
stdout. The input is a schema, a line containing only `--`, then requests:

```
message Inner { sint32 v = 1; }
message Outer {
  int32 a = 1;
  string b = 2;
  repeated int32 c = 3;
  Inner d = 4;
}
--
encode Outer {a: 1, b: "x", c: [1, 2], d: {v: -5}}
decode Outer 08011201781a02010222020809
decode Outer 08ff
```

prints

```
08011201781a02010222020809
{a: 1, b: "x", c: [1, 2], d: {v: -5}}
error
```

- `decode <Message> <hex>` prints the canonical text form; `decode <Message>`
  with nothing after the name decodes zero bytes.
- `encode <Message> <text>` prints the lowercase hex of the canonical
  encoding (an empty line for an empty encoding).
- Any malformed request prints `error`. The exit status is 0 regardless.

The schema language is `message Name { [repeated] type name = number; ... }`
with the scalar types `int32 int64 uint32 uint64 sint32 sint64 bool fixed32
fixed64 sfixed32 sfixed64 string bytes` or message names (forward and
recursive references allowed). The exact text and wire rules are in the
problem's `SPEC.md`.

## Library usage

```go
package main

import (
	"fmt"
	"log"

	"example.com/protowire"
)

func main() {
	schema, err := protowire.ParseSchema(`
		message Inner { sint32 v = 1; }
		message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }`)
	if err != nil {
		log.Fatal(err)
	}
	outer := schema.Message("Outer")

	// Text -> wire.
	m, err := outer.ParseText([]byte(`{c: [1, 2], b: "x", a: 1, d: {v: -5}}`))
	if err != nil {
		log.Fatal(err)
	}
	wire := m.Marshal()
	fmt.Printf("%x\n", wire) // 08011201781a02010222020809

	// Wire -> text.
	decoded, err := outer.Unmarshal(wire)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(decoded) // {a: 1, b: "x", c: [1, 2], d: {v: -5}}

	// Typed access.
	b, _ := decoded.Get("b")
	fmt.Println(b.(string)) // x
}
```

## Layout

| Path | Responsibility |
|---|---|
| `schema.go` | schema parsing; `Schema`, `MessageDesc`, `Field`, `Kind` |
| `wire.go` | varints, tags, length prefixes, skipping unknown fields and groups |
| `message.go` | the value tree (`Message`) and typed accessors |
| `decode.go` | `MessageDesc.Unmarshal` |
| `encode.go` | `Message.Marshal` (sizes computed once, then one write pass) |
| `text.go` | canonical text printing and the text parser |
| `internal/batch` | the request/response protocol used by the CLI |
| `cmd/protowire` | the command-line entry point |

Errors wrap `ErrSchema`, `ErrDecode` or `ErrText` so callers can test them
with `errors.Is`.
