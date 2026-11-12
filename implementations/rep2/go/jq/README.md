# jq

A small implementation of a subset of the [jq](https://jqlang.github.io/jq/)
filter language (semantics of jq 1.7, `jq -c`), written in Go with only the
standard library. It has its own JSON parser, JSON serializer and a lazy
tree-walking filter interpreter, packaged as a reusable library
(`example.com/jq`) plus a thin command-line tool.

## Layout

| File | Responsibility |
|---|---|
| `value.go` | `Value` model, `TypeName`, `Truthy` |
| `object.go` | insertion-ordered `Object` with O(1) lookup, cached sorted keys |
| `compare.go` | jq's total ordering: `Compare`, `Equal` |
| `decode.go`, `encode.go` | JSON parser (`ParseJSON`) and compact serializer (`Marshal`) |
| `lexer.go`, `parser.go` | filter tokenizer and recursive-descent parser (`Compile`) |
| `ast.go` | syntax-tree nodes and their streaming evaluation |
| `ops.go` | indexing, slicing, arithmetic |
| `builtins.go` | builtins (`map`, `sort_by`, `add`, `keys`, ...) |
| `cmd/jq` | the command-line tool |

Values are immutable and shared, never deep-copied. Evaluation is
callback-driven, so results stream out one at a time and an error stops
evaluation at the point it occurs.

## Build

```
./build.sh          # runs: go build -o bin/jq ./cmd/jq
go test ./...       # run the unit tests
```

## Command line

`bin/jq` (or `./run.sh`) reads **all of stdin**: the first line is the filter,
the rest is exactly one JSON document. Every result is printed as compact JSON,
one per line. If evaluation raises an uncaught error, the results produced so
far are printed, then a line `error`, and nothing more. The exit status is 0.

```
$ printf '.users | map(select(.age >= 30)) | map(.name)\n{"users":[{"name":"ann","age":31},{"name":"bo","age":20}]}' | ./run.sh
["ann"]

$ printf '[(1,2) + (10,20)], (.[] | .a?)\n[{"a":1},5]' | ./run.sh
[11,12,21,22]
1
```

## Supported language

Identity and paths (`.`, `.a`, `."a b"`, `.[e]`, `.[]`, `.[a:b]`, with `?`),
literals, `$variables`, `E as $x | body`, `reduce`, `if/elif/else`, array and
object construction (`{a, "b", $c, (k): v}`), `|` `,` `and` `or` `not`,
comparisons, `+ - * / %`, `try` via `?`, and the builtins `empty`, `error`,
`error(f)`, `not`, `length`, `keys`, `has`, `type`, `add`, `select`, `map`,
`sort`, `sort_by`, `group_by`, `unique`, `reverse`, `min`, `max`, `tostring`,
`tonumber`. The full behaviour is specified in `problems/jq/SPEC.md` of the
surrounding repository.

## Library example

```go
package main

import (
	"fmt"
	"log"

	"example.com/jq"
)

func main() {
	filter, err := jq.Compile(`.users | map(select(.age >= 30)) | sort_by(.age) | map(.name)`)
	if err != nil {
		log.Fatal(err)
	}
	doc, err := jq.ParseJSON([]byte(`{"users":[{"name":"ann","age":31},{"name":"bo","age":20},{"name":"cy","age":30}]}`))
	if err != nil {
		log.Fatal(err)
	}
	// Run streams results; returning an error from the callback stops evaluation.
	err = filter.Run(doc, func(v jq.Value) error {
		fmt.Println(string(jq.Marshal(v))) // ["cy","ann"]
		return nil
	})
	if err != nil { // a *jq.Error for runtime errors raised by the filter
		log.Fatal(err)
	}
}
```

`Filter.Collect` gathers all results into a slice. Values are plain Go types:
`nil`, `bool`, `float64`, `string`, `[]jq.Value` and `*jq.Object`.
