# jsoncanon

A strict JSON (RFC 8259) parser and canonical serializer in Go, written from
scratch on the standard library only (no `encoding/json`).

It reads one JSON document and prints its canonical form: no insignificant
whitespace, minimal string escaping, normalized number exponents, duplicate
object keys collapsed (last wins) and object members sorted by the UTF-16 code
units of their keys. Numbers are echoed as text, never converted to floating
point, so arbitrarily large integers survive unchanged. Nesting is limited to
512 levels; invalid UTF-8, a BOM, lone surrogates and every other grammar
violation make the document invalid.

## Layout

| File | Responsibility |
|------|----------------|
| `utf8.go` | strict UTF-8 validation |
| `parse.go`, `parse_string.go`, `parse_number.go` | recursive-descent parser: structure, strings, numbers |
| `value.go` | the `Value` tree |
| `order.go` | UTF-16 key ordering |
| `serialize.go` | single-buffer canonical serializer |
| `cmd/jsoncanon` | command-line tool |

## Build

Requires Go 1.27 or later.

```
./build.sh          # writes bin/jsoncanon
go test ./...       # run the tests
```

## Command line

```
echo '{ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null }' | ./run.sh
{"a":"héllo/","b":null}
```

The whole of stdin is the document. The output is one line: the canonical form
or `invalid`. The exit status is 0 in both cases.

## Library

```go
package main

import (
	"fmt"

	"github.com/example/jsoncanon"
)

func main() {
	out, err := jsoncanon.Canonicalize([]byte(`{"b":1e+05,"a":[true,"x"]}`))
	if err != nil {
		fmt.Println("invalid:", err)
		return
	}
	fmt.Println(string(out)) // {"a":[true,"x"],"b":1e5}

	v, _ := jsoncanon.Parse([]byte(`[1,2]`))
	fmt.Println(v.Kind, len(v.Elems)) // array 2
}
```

`Parse` returns a `*Value` tree (strings decoded, numbers as canonical text,
objects with all members in input order); `Value.AppendCanonical` serializes
it. Errors are `*SyntaxError` with a byte offset.
