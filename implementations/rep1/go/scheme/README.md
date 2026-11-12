# scheme

A small Scheme interpreter written in Go, as a reusable library plus a thin
command-line tool. It implements a deliberately small subset of Scheme:
arbitrary-precision integers, strings, symbols, pairs, closures, proper tail
calls, and the special forms `quote`, `if`, `define`, `set!`, `lambda`, `let`
(including named `let`), `let*`, `letrec`, `begin`, `cond`, `and` and `or`.

Only the Go standard library is used. In particular the bignum arithmetic is
implemented from scratch in `bigint` (schoolbook multiplication, Knuth's
Algorithm D division, decimal output by repeated division by 10^9); `math/big`
is not used.

## Layout

| path | responsibility |
|---|---|
| `bigint/` | arbitrary-precision signed integers |
| `reader.go` | source text → datums |
| `analyze.go` | datums → node tree (each form analysed once) |
| `eval.go`, `env.go` | trampolined evaluator and environment frames |
| `builtins.go`, `numeric.go` | primitive procedures and integer arithmetic |
| `printer.go` | `write` / `display` forms |
| `interp.go`, `errors.go`, `value.go` | public API, errors and value types |
| `cmd/scheme/` | the command-line tool |

## Build

```
./build.sh          # runs: go build -o bin/scheme ./cmd/scheme
```

## Command-line use

The program is read from standard input; results go to standard output.

```
$ echo '(define (sq x) (* x x)) (sq 12) (display "hi") (newline)' | ./run.sh
144
hi
```

Each top-level value that is not void is printed on its own line (strings
quoted); `display` and `newline` write as they run. On a runtime error the
output so far is kept, `error: <category>` is appended and evaluation stops
(`unbound-variable`, `type-error`, `arity-error`, `division-by-zero`,
`user-error`). The exit status is 0 either way.

## Library use

```go
package main

import (
	"fmt"
	"os"

	"example.com/scheme"
)

func main() {
	in := scheme.New(os.Stdout)

	// Extend the global environment with a Go primitive.
	in.DefinePrimitive("double", 1, 1, func(_ *scheme.Interp, a []scheme.Value) scheme.Value {
		n, ok := a[0].(scheme.Int)
		if !ok {
			scheme.Raise(scheme.ErrType)
		}
		return n * 2
	})

	// Run prints every non-void top-level value, like the CLI.
	if err := in.Run(`(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
	                  (fact 25)`); err != nil {
		fmt.Println(err)
	}

	// Eval returns the value of the last form instead of printing it.
	v, err := in.Eval(`(double 21)`)
	fmt.Println(scheme.Write(v), err) // 42 <nil>
}
```

Runtime errors are returned as `*scheme.Error` (with a `Kind`), malformed
source as `*scheme.SyntaxError`.

## Tests

```
go test ./...
```
