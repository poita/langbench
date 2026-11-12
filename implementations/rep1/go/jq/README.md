# jq (subset) in Go

A from-scratch interpreter for a subset of the [jq](https://jqlang.github.io/jq/)
query language (semantics of jq 1.7 with `-c`), packaged as a reusable Go
library and a small command-line tool. It uses only the Go standard library:
the JSON parser, the JSON serializer and the filter interpreter are all
implemented here.

## Layout

| Path | Responsibility |
|---|---|
| `jq.go` | Public facade: `Compile`, `Query.Run/All/Iter`, `ParseJSON`, `Marshal` |
| `value/` | Data model (`Value`, insertion-ordered immutable `Object`), jq ordering, stable sort, JSON decoder and encoder |
| `syntax/` | Lexer, recursive-descent parser and AST for filters |
| `interp/` | Compiles the AST to closures and evaluates them lazily, plus the builtins |
| `cmd/jq/` | The command-line tool |
| `testdata/` | Golden filter/document/output cases used by the CLI tests |

Design notes: values are immutable and shared, never deep-copied; objects keep
insertion order with O(1) expected lookup (a hash index is built lazily for
larger objects) and cache their sorted key order; sorting is a stable merge
sort that evaluates each sort key once; evaluation is push-based, so outputs
are produced one at a time, in order, and an error stops the stream at the
point it occurs.

## Build

Requires Go 1.27 or newer.

```sh
./build.sh          # builds ./bin/jq  (same as: go build -o bin/jq ./cmd/jq)
go test ./...       # runs the unit and golden tests
```

## Command-line use

The tool reads standard input: the **first line is the filter**, everything
after it is **one JSON document**. Each result is printed as compact JSON, one
per line. If evaluation raises an error that is not caught with `?`, the
results produced before it are printed, then a line `error`, and nothing more.
The exit status is 0 (non-zero only if stdin/stdout themselves fail).

```sh
$ printf '%s\n%s\n' '.users | map(select(.age >= 30)) | map(.name)' \
    '{"users":[{"name":"al","age":31},{"name":"bo","age":20}]}' | ./run.sh
["al"]
```

`run.sh` runs the built binary from any directory.

## Supported language

* Paths: `.`, `.a`, `."a b"`, `.[e]`, `.[]`, `.[a:b]`, `.[:b]`, `.[a:]`, chained;
  `?` after a path operation tolerates errors of just that operation, after
  anything else it acts as `try`.
* Operators: `|`, `,`, `or`, `and`, `== != < <= > >=`, `+ - * / %`, unary `-`.
* `if/elif/else/end`, `E as $x | body`, `reduce SRC as $x (INIT; UPDATE)`.
* Construction: `[...]`, `{a, "b", $x, k: v, (expr): v}`.
* Builtins: `empty error error(f) not length keys has(k) type add select(f)
  map(f) sort sort_by(f) group_by(f) unique reverse min max tostring tonumber`.

Numbers are IEEE-754 doubles; integral values print without a decimal point.
Comparison follows jq's order `null < false < true < numbers < strings <
arrays < objects`.

## Library use

```go
package main

import (
	"fmt"

	"example.com/jq"
)

func main() {
	q, err := jq.Compile(`.users | map(select(.age >= 30)) | sort_by(.age) | map(.name)`)
	if err != nil {
		panic(err) // *jq.SyntaxError for malformed filters
	}
	doc, err := jq.ParseJSON([]byte(`{"users":[
		{"name":"bo","age":45},{"name":"al","age":31},{"name":"cy","age":20}]}`))
	if err != nil {
		panic(err)
	}

	// Streaming: yield is called once per output, in order. Returning an error
	// from yield stops evaluation and is returned by Run.
	err = q.Run(doc, func(v jq.Value) error {
		fmt.Println(string(jq.Marshal(v))) // ["al","bo"]
		return nil
	})

	// Or collect everything, or range over the outputs:
	outs, err := q.All(doc)
	_ = outs
	for v, err := range q.Iter(doc) {
		_, _ = v, err // a runtime error arrives as the last (nil, err) pair
	}
}
```

A `jq.Value` is `nil`, `bool`, `float64`, `string`, `[]jq.Value` or
`*jq.Object`; build your own input with `value.NewBuilder` for objects.
Runtime failures are returned as `*jq.RuntimeError`; compiled queries are
immutable and safe for concurrent use.
