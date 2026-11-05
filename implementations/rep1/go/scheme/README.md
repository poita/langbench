# scheme

A small Scheme interpreter written in Go, usable as a library and as a
command-line tool. It uses only the Go standard library; the arbitrary-precision
integer arithmetic is implemented from scratch in package `bigint`.

## Features

- Special forms: `quote`, `if`, `define`, `set!`, `lambda`, `let` (including
  named `let`), `let*`, `letrec`, `begin`, `cond`, `and`, `or`.
- Proper tail calls in every tail position (including through `apply`);
  non-tail recursion is limited only by memory.
- Arbitrary-precision integers (fixnums that promote to bignums on overflow).
- Primitives: arithmetic and comparison, pairs and lists, predicates,
  `eq?`/`equal?`, `apply`, `error`, a few string/symbol operations, `display`
  and `newline`.

## Design

Source is read by an index-based recursive-descent reader, each top-level form
is compiled once into a tree of pre-analysed nodes, and a single trampolined
evaluator runs the tree (tail positions loop instead of recursing). Operands go
through one shared argument stack; environments are heap frames of
`(symbol id, value)` slots, with globals in an array indexed by symbol id.

## Layout

| Path | Contents |
|---|---|
| `bigint/` | sign-magnitude bignums in base 2³²: schoolbook multiply, Knuth division, base-10⁹ decimal conversion |
| `reader.go` | the reader (text → datums) |
| `compile.go` | datums → node tree |
| `eval.go`, `env.go` | the evaluator and environment frames |
| `prims.go`, `numeric.go` | primitives and integer arithmetic on values |
| `printer.go` | write/display forms |
| `interp.go`, `value.go`, `errors.go` | public API: `Interp`, `Value`, `Error` |
| `cmd/scheme/` | the command-line tool |

## Build

```sh
./build.sh          # or: go build -o bin/scheme ./cmd/scheme
go test ./...       # unit tests
```

## Command-line use

The program is read from standard input; results go to standard output.

```sh
echo '(define (sq x) (* x x)) (sq 12345678901234567890) (display "hi") (newline)' | ./run.sh
```

prints

```
152415787532388367501905199875019052100
hi
```

The printed value of every top-level form whose value is not void is written
on its own line. On a runtime error, `error: <category>` is written and
evaluation stops (categories: `unbound-variable`, `type-error`, `arity-error`,
`division-by-zero`, `user-error`). The exit code is always 0.

## Library use

```go
package main

import (
	"fmt"

	"example.com/scheme"
)

func main() {
	in := scheme.New()

	// Run evaluates every form and prints non-void results to the output buffer.
	err := in.Run([]byte(`
(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
(fact 25)
(display "done") (newline)`))
	fmt.Print(string(in.Output())) // 15511210043330985984000000 / done
	if err != nil {
		fmt.Println(err) // e.g. "error: unbound-variable" (a *scheme.Error)
	}

	// Eval returns the value of the last form; definitions persist.
	v, _ := in.Eval(`(list 1 "two" 'three)`)
	fmt.Println(v.String())  // (1 "two" three)
	fmt.Println(v.Display()) // (1 two three)
}
```

The big-integer package can be used on its own:

```go
x, _ := bigint.Parse("123456789012345678901234567890")
q, r, _ := x.Mul(x).QuoRem(bigint.FromInt64(97))
fmt.Println(q, r)
```
