# jq (Go)

A from-scratch implementation of a subset of the [jq](https://jqlang.github.io/jq/)
query language (semantics of jq 1.7, `jq -c`), written in Go with the standard
library only. It has its own JSON parser, JSON serialiser and filter
interpreter; no `encoding/json` is used.

## Build

Requires Go 1.27 or newer.

```sh
./build.sh          # builds bin/jq   (equivalent to: go build -o bin/jq ./cmd/jq)
go test ./...       # unit tests
```

## Command-line use

The program reads all of standard input: the first line is the **filter**, the
rest is **one JSON document**. Every result is printed as compact JSON, one per
line. If evaluation fails, the results produced before the failure are printed
followed by a single line `error`. The exit status is 0 in both cases.

```sh
$ printf '.users | map(select(.age >= 30)) | map(.name)\n{"users":[{"name":"ann","age":31},{"name":"bo","age":20}]}' | ./run.sh
["ann"]

$ printf '.[] | .a.b?\n[{"a":{"b":1}},{"a":5},3]' | ./run.sh
1
error
```

`run.sh` simply runs `bin/jq`, so run `build.sh` first. Malformed filters or
documents are reported on stderr with a non-zero exit status.

## Supported language

* Paths: `.`, `.foo`, `."foo"`, `.[e]`, `.[]`, `.[a:b]`, with `?` after each
  (per-operation tolerance) or after any other term (`try`).
* Literals, `$var`, `( )`, array `[ ]` and object `{ }` construction
  (`{a}`, `{"a":1}`, `{(expr): v}`, `{$x}`).
* Operators: `|`, `,`, `+ - * / %`, `== != < <= > >=`, `and`, `or`, unary `-`.
* `if/elif/else/end`, `E as $x | body`, `reduce SRC as $x (INIT; UPDATE)`.
* Builtins: `empty error error(f) not length keys has(k) type add select(f)
  map(f) sort sort_by(f) group_by(f) unique reverse min max tostring tonumber`.

Generator ordering (right operand of binary operators as the outer loop,
nested loops in object construction, ...), the total ordering of values and
insertion-ordered objects follow jq; see `problems/jq/SPEC.md` in the task
repository for the exact rules.

## Library

The repository is a Go module, `example.com/jq`:

| Package | Responsibility |
|---|---|
| `example.com/jq` | The public entry point: `Compile`, `Program.Run`, `Program.Query`, `ParseJSON`, `Marshal`. |
| `example.com/jq/value` | Immutable values (null, bool, number, string, array, insertion-ordered object), the total ordering, arithmetic, indexing and slicing. |
| `example.com/jq/jsonio` | JSON parser (with object-key interning) and compact serialiser. |
| `example.com/jq/syntax` | Lexer, recursive-descent parser and syntax tree for filters. |
| `example.com/jq/interp` | The push-style tree-walking evaluator and the builtins. |
| `cmd/jq` | The command-line tool. |

Design notes: values are a 24-byte struct with numbers, booleans and null
stored inline and strings/arrays/objects shared by reference; objects keep an
entry vector with a lazily built hash index (above 8 keys) and a memoised
sorted-key permutation; generators are callbacks (`eval(node, input, env,
sink)`); `sort_by`/`group_by` evaluate their key once per element and sort
(key, index) pairs with `slices.SortFunc`.

### Example

```go
package main

import (
	"fmt"
	"log"

	"example.com/jq"
)

func main() {
	prog, err := jq.Compile(`.users | map(select(.age >= 30)) | sort_by(.age) | map(.name)`)
	if err != nil {
		log.Fatal(err)
	}
	doc, err := jq.ParseJSON([]byte(`{"users":[
		{"name":"ann","age":31}, {"name":"bo","age":20}, {"name":"cy","age":30}]}`))
	if err != nil {
		log.Fatal(err)
	}

	// Stream the results...
	err = prog.Run(doc, func(v jq.Value) error {
		fmt.Println(jq.Marshal(v)) // ["cy","ann"]
		return nil
	})
	if err != nil { // *jq.Error when the filter itself failed
		log.Fatal(err)
	}

	// ...or collect them.
	out, err := prog.Query(doc)
	fmt.Println(len(out), err) // 1 <nil>
}
```
