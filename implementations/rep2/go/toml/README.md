# toml

A from-scratch **TOML 1.0.0** parser and serializer in Go, using only the
standard library. It decodes TOML into a tree, converts that tree to and from
the "tagged JSON" format used by the [toml-test](https://github.com/toml-lang/toml-test)
suite, and writes canonical TOML. A small command-line tool exposes this on
stdin/stdout.

The parser is strict: it rejects bad UTF-8, a BOM, stray carriage returns,
control characters in strings and comments, non-ASCII digits, out-of-range
integers, invalid dates, and every table-redefinition error in the TOML
specification.

## Layout

| Path             | Responsibility                                           |
|------------------|----------------------------------------------------------|
| `node.go`        | the `Node` tree, `Kind`, constructors and accessors      |
| `parser.go`      | statements, headers, arrays, inline tables, table rules  |
| `strings.go`     | keys and the four string syntaxes                        |
| `scalar.go`      | integers, floats, booleans, date-times                   |
| `tagged.go`      | tagged JSON writer and reader                            |
| `encode.go`      | canonical TOML writer                                    |
| `cmd/toml`       | the command-line tool                                    |

## Build

```
./build.sh          # runs: go build -o bin/toml ./cmd/toml
go test ./...       # unit tests
```

Requires Go 1.27 or later; there are no dependencies.

## Command line

`./run.sh` (or `bin/toml`) reads stdin. The first line is the mode, `decode` or
`encode`; the rest is the document.

```
$ printf 'decode\nname = "Tom"\nports = [8001, 8002]\n' | ./run.sh
{"name":{"type":"string","value":"Tom"},"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]}

$ printf 'decode\na = \n' | ./run.sh
error

$ printf 'encode\n{"a":{"type":"bool","value":"true"}}' | ./run.sh
a = true
```

* **decode** prints compact, key-sorted tagged JSON, or `error` for an invalid
  document. Floats are printed as 17 significant digits (`%.16e`), `nan`, `inf`
  or `-inf`; date-times are canonicalised textually (`T` separator, trimmed
  fraction, `Z` for zero offsets).
* **encode** prints canonical TOML: plain pairs first (sorted), then each
  sub-table and array of tables with an explicit header.

The exit status is always 0.

## Library

```go
package main

import (
	"fmt"
	"log"

	"example.com/toml"
)

func main() {
	root, err := toml.Parse([]byte(`
title = "demo"
[owner]
born = 1979-05-27T07:32:00-08:00
[[servers]]
port = 8001
`))
	if err != nil {
		log.Fatal(err) // *toml.Error carries Line and Col
	}

	fmt.Println(root.Get("title").Text())                  // demo
	fmt.Println(root.Get("owner").Get("born").Kind())      // 6 (KindDatetime)
	fmt.Println(root.Get("servers").At(0).Get("port").Int64()) // 8001

	// Tagged JSON and canonical TOML.
	fmt.Printf("%s\n", toml.MarshalTaggedJSON(root))
	out, _ := toml.MarshalTOML(root)
	fmt.Print(string(out))

	// Build a tree by hand.
	t := toml.NewTable()
	t.Set("n", toml.NewInteger(7))
	out, _ = toml.MarshalTOML(t)
	fmt.Print(string(out)) // n = 7
}
```

Public API summary:

* `Parse([]byte) (*Node, error)` — TOML to tree.
* `MarshalTaggedJSON(*Node) []byte`, `ParseTaggedJSON([]byte) (*Node, error)`.
* `MarshalTOML(*Node) ([]byte, error)` — canonical TOML.
* `Node` accessors: `Kind`, `Text`, `Int64`, `Float64`, `Bool`, `Get`, `Keys`,
  `Len`, `At`, `Items`; builders: `NewTable`, `NewArray`, `NewString`,
  `NewInteger`, `NewFloat`, `NewBool`, `NewDatetime`, `Set`, `Append`.

Date-times are kept as text; no calendar arithmetic or time-zone conversion is
done. Decisions where TOML leaves a choice: leap seconds (`:60`) are rejected,
`-00:00` is read as UTC (`Z`), NaN loses its sign, and the 64-bit signed
integer range is enforced in every base.
