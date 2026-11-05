# jq (Go)

A small interpreter for a subset of the [jq](https://jqlang.github.io/jq/)
filter language, written in Go using only the standard library. It follows
jq 1.7 semantics (`jq -c` output) for the supported subset: paths, slices,
optional `?`/`try`, generators and their ordering, arithmetic, comparison,
`if`, `as` bindings, `reduce`, object/array construction and a set of
builtins (`length keys has type add select map sort sort_by group_by unique
reverse min max tostring tonumber empty error not`).

The JSON parser, the serializer and the filter interpreter are all
implemented here; no JSON or jq library is used.

## Layout

| Path | Contents |
|---|---|
| `value/` | Immutable value model, insertion-ordered objects, total ordering, JSON parser and compact encoder |
| `*.go` (package `jq`) | Lexer, parser, push-style evaluator, operators, builtins, public API |
| `cmd/jq/` | The command-line tool |

## Build

```
./build.sh          # produces bin/jq
go test ./...       # unit tests
```

Requires Go 1.27 or newer.

## Command line

`bin/jq` (or `./run.sh`) reads all of standard input: the first line is the
filter, everything after the first newline is one JSON document. Every result
is printed as compact JSON on its own line. If evaluation raises an uncaught
error, the results produced before it are printed, then a line `error`. The
exit status is 0.

```
$ printf '%s\n%s' '.users | map(select(.age >= 30)) | map(.name)' \
    '{"users":[{"name":"ann","age":31},{"name":"ed","age":29}]}' | ./run.sh
["ann"]
```

## Library

```go
package main

import (
	"fmt"

	"jq"
	"jq/value"
)

func main() {
	q, err := jq.Compile(`.items | map(.price * .qty) | add`)
	if err != nil {
		panic(err)
	}
	doc, err := value.ParseString(`{"items":[{"price":2.5,"qty":2},{"price":4,"qty":1}]}`)
	if err != nil {
		panic(err)
	}
	err = q.Run(doc, func(v value.Value) error {
		fmt.Println(value.JSON(v)) // 9
		return nil
	})
	if err != nil {
		fmt.Println("runtime error:", err) // *jq.Error
	}
}
```

* `jq.Compile(src) (*Query, error)` parses a filter.
* `(*Query).Run(input, emit)` streams every output to `emit`; evaluation stops
  at the first runtime error (a `*jq.Error`) or the first error from `emit`.
* `(*Query).Collect(input)` returns the outputs produced before any error.
* `value.Parse` / `value.ParseString` parse JSON; `value.JSON` /
  `value.AppendJSON` serialise; `value.Compare` is jq's total order.

## Design notes

* Values are small tagged structs; numbers, booleans and null are inline.
  Strings, arrays and objects are shared immutable references.
* Objects are insertion-ordered entry vectors with a lazily built hash index
  above 12 keys; sorted key order is computed once per object and memoised.
  JSON object keys are interned.
* Evaluation is push-style (`eval(node, input, env, sink)`); nodes statically
  known to produce exactly one output take a callback-free fast path.
* `sort_by`/`group_by` evaluate their key once per element and sort an index
  permutation (stable via index tie-break).
* `add` folds into one private builder, so it is linear in the total size.
