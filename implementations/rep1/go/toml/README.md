# toml

A from-scratch **TOML 1.0.0** parser and serializer in Go, using only the
standard library. It has a reusable library (package `toml`) and a small
command-line tool that converts between TOML and the *tagged JSON* format of
the [toml-test](https://github.com/toml-lang/toml-test) suite.

## Build

Requires Go 1.27.1.

```sh
./build.sh          # builds bin/toml
go test ./...       # unit tests
```

## Command-line tool

`bin/toml` (or `./run.sh`) reads all of stdin. The first line is the mode, the
rest is the document:

```sh
printf 'decode\nname = "Tom"\n[db]\nports = [8001, 8002]\n' | ./run.sh
# {"db":{"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]},"name":{"type":"string","value":"Tom"}}

printf 'encode\n{"a":{"type":"integer","value":"1"}}' | ./run.sh
# a = 1
```

- `decode`: parses TOML and prints compact, key-sorted tagged JSON on one
  line, or `error` if the document is not valid TOML 1.0.0.
- `encode`: reads tagged JSON and prints canonical TOML (pairs first, then
  sub-tables and arrays of tables, keys sorted).

The exit code is 0 for both outcomes of decode.

## Library

```go
package main

import (
	"fmt"

	"github.com/example/toml"
)

func main() {
	doc, err := toml.Parse([]byte("title = 'demo'\n[owner]\nborn = 1979-05-27T07:32:00-08:00\n"))
	if err != nil {
		fmt.Println(err) // *toml.SyntaxError with the line number
		return
	}
	owner, _ := doc.Get("owner")
	born, _ := owner.(*toml.Table).Get("born")
	fmt.Println(born.(*toml.Value).Type, born.(*toml.Value).Text)
	// datetime 1979-05-27T07:32:00-08:00

	fmt.Printf("%s\n", doc.TaggedJSON()) // tagged JSON
	fmt.Printf("%s", doc.TOML())         // canonical TOML
}
```

Public API:

| Item | Purpose |
|------|---------|
| `Parse(src []byte) (*Table, error)` | Parse a TOML document; errors are `*SyntaxError`. |
| `ParseTaggedJSON(src []byte) (*Table, error)` | Read a tagged JSON tree. |
| `(*Table).TaggedJSON()` / `AppendTaggedJSON(dst)` | Compact key-sorted tagged JSON. |
| `(*Table).TOML()` / `AppendTOML(dst)` | Canonical TOML text. |
| `Table`, `Array`, `Value` (`Node`) | The document tree. Scalars keep canonical text (floats as `%.16e`, date-times normalised). |

## Layout

| File | Responsibility |
|------|----------------|
| `node.go`, `errors.go` | tree types and `SyntaxError` |
| `parse.go` | UTF-8/BOM/CR validation, lines, keys, arrays, inline tables |
| `tables.go` | table resolution rules (explicit / implicit / dotted / inline) |
| `strings.go` | the four string forms and escapes |
| `scalar.go` | booleans, integers, floats, date-times |
| `taggedjson_write.go`, `taggedjson_read.go` | tagged JSON output and input |
| `encode.go` | canonical TOML output |
| `cmd/toml` | the command-line tool |
