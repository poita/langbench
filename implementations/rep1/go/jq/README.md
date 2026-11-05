# jq

A dependency-free Go implementation of a subset of the [jq](https://jqlang.github.io/jq/)
query language (jq 1.7 semantics, `jq -c` output). It has a reusable library and a thin
command-line tool. The JSON parser, JSON serialiser and filter interpreter are all written
from scratch using only the Go standard library.

## Layout

| Package | Responsibility |
|---|---|
| `github.com/peter/jq` | Public facade: `Compile`, `Query.Run`, `ParseJSON`, `Marshal` |
| `value` | Immutable value model, total ordering, insertion-ordered objects, JSON parser and serialiser |
| `syntax` | Filter lexer, recursive-descent parser and AST |
| `interp` | Compiler (variable and builtin resolution) and push-style tree-walking evaluator |
| `cmd/jq` | The command-line tool |

Design notes: values are a small tagged struct (numbers, booleans and null are stored inline;
strings, arrays and objects are shared immutable references). Objects are insertion-ordered
entry vectors with a hash index above 16 keys, interned keys from the JSON parser and a
memoised sorted-key permutation. Evaluation calls a sink function per output, so generators
are nested callbacks; `sort_by`/`group_by` compute each key once and sort an index permutation.

## Build

Requires Go 1.27 or newer.

```sh
./build.sh          # builds bin/jq
go test ./...       # unit tests
```

`build.sh` and `run.sh` work from any directory.

## Command-line use

The program reads all of stdin. The first line is the filter; the rest is one JSON document.
Every result is printed as one line of compact JSON. If evaluation raises an uncaught error,
the results produced before it are printed, followed by a line `error`, and evaluation stops.
The exit status is 0 (non-zero only for a malformed filter or document, or an I/O failure).

```sh
$ printf '.users | map(select(.age >= 30)) | map(.name)\n{"users":[{"name":"ann","age":31},{"name":"bob","age":20}]}' | ./run.sh
["ann"]

$ printf '[(1,2) + (10,20)], {a:(1,2)}\nnull' | ./run.sh
[11,12,21,22]
{"a":1}
{"a":2}
```

## Supported language

Identity, field/index/iterate/slice (with `?`), `try`-style `?`, literals, variables with
`as`, `reduce`, `if/elif/else`, `,` and `|`, arithmetic (`+ - * / %`), comparisons,
`and`/`or`, unary minus, array and object construction, and the builtins `empty`, `error`,
`not`, `length`, `keys`, `has`, `type`, `add`, `select`, `map`, `sort`, `sort_by`,
`group_by`, `unique`, `reverse`, `min`, `max`, `tostring`, `tonumber`. The full semantics
(ordering, evaluation order of generators, object key order) are those of jq 1.7.

## Library use

```go
package main

import (
	"fmt"
	"log"

	"github.com/peter/jq"
)

func main() {
	q, err := jq.Compile(`.users | map(select(.age >= 30) | .name)`)
	if err != nil {
		log.Fatal(err)
	}
	doc, err := jq.ParseJSON(`{"users":[{"name":"ann","age":31},{"name":"bob","age":20}]}`)
	if err != nil {
		log.Fatal(err)
	}
	err = q.Run(doc, func(v jq.Value) error {
		fmt.Println(jq.Marshal(v)) // ["ann"]
		return nil
	})
	if err != nil {
		log.Fatal(err) // a *jq.RuntimeError if the filter raised an error
	}
}
```

`Query.All` collects the outputs into a slice. A compiled `Query` is immutable and safe for
concurrent use. Values can also be built and inspected through package `value`
(`value.Number`, `value.String`, `value.Array`, `value.ObjectBuilder`, `Value.Kind`, ...).
