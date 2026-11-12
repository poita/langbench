# toml

A strict TOML 1.0.0 parser and canonical serializer in Go, using only the
standard library. It comes as a reusable library plus a small command-line
tool that converts between TOML and the *tagged JSON* format of the
[toml-test](https://github.com/toml-lang/toml-test) suite.

## Layout

| Path             | Purpose                                                        |
|------------------|----------------------------------------------------------------|
| `node.go`        | Document tree: `Table`, `Array`, `Value`, `Type`               |
| `decode.go`      | `Parse`, statements, key/header resolution and table rules      |
| `strings.go`     | The four string forms and escapes                               |
| `number.go`      | Integers, floats and scalar-token dispatch                      |
| `datetime.go`    | Date/time validation and canonicalisation (no date library)     |
| `encode.go`      | `Encode`: canonical TOML output                                 |
| `tagged/`        | Tagged JSON reader and writer                                   |
| `cmd/toml/`      | The command-line tool                                           |

## Build

Requires Go 1.27 or newer.

```sh
./build.sh          # builds bin/toml  (or: go build -o bin/toml ./cmd/toml)
go test ./...       # runs the tests
```

## Command-line use

`bin/toml` (or `./run.sh`) reads standard input. The first line is the mode,
`decode` or `encode`; everything after it is the document.

```sh
$ printf 'decode\nname = "Tom"\nports = [8001, 8002]\n' | ./run.sh
{"name":{"type":"string","value":"Tom"},"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]}

$ printf 'encode\n{"a":{"type":"integer","value":"1"}}' | ./run.sh
a = 1
```

* **decode** prints the document as compact, key-sorted tagged JSON, or the
  single word `error` if it is not valid TOML 1.0.0.
* **encode** prints the canonical TOML for a tagged JSON tree: pairs before
  sub-tables, keys in code point order, a header for every table, strings
  always as basic strings.

The exit code is 0 in both cases. Scalar text forms (17-digit floats,
normalised date-times, decimal integers) are specified in the problem's
`SPEC.md`.

## Library use

```go
package main

import (
	"fmt"
	"log"

	"example.com/toml"
	"example.com/toml/tagged"
)

func main() {
	doc := []byte(`
title = "example"
[owner]
dob = 1979-05-27T07:32:00-08:00
`)
	root, err := toml.Parse(doc) // *toml.SyntaxError on invalid input
	if err != nil {
		log.Fatal(err)
	}

	n, _ := root.Lookup("owner", "dob")
	v := n.(*toml.Value)
	fmt.Println(v.Type, v.Text) // datetime 1979-05-27T07:32:00-08:00

	fmt.Printf("%s\n", tagged.Marshal(root)) // tagged JSON
	fmt.Printf("%s", toml.Encode(root))      // canonical TOML
}
```

Scalars are kept as canonical text rather than converted to Go types, so
dates and numbers round-trip exactly. A `*toml.Value` carries its `Type` and
`Text`.
