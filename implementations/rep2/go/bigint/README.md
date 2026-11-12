# bigint

Signed arbitrary-precision integer arithmetic in Go, written from scratch with
only the standard library (no `math/big`). It provides a small library and a
command-line tool that evaluates one query per line.

Supported: addition, subtraction, multiplication, truncating division,
remainder (C semantics), exponentiation and comparison on decimal integers with
tens of thousands of digits.

## Design

- An `Int` is a sign plus a magnitude of little-endian `uint32` limbs in base
  10^9, so parsing and printing are linear in the number of digits.
- Add / subtract / compare: O(n + m).
- Multiply: schoolbook, O(n·m).
- Divide / remainder: Knuth's Algorithm D, computing quotient and remainder
  together, O((n − m + 1)·m).
- Power: binary exponentiation (repeated squaring).

## Layout

| Path                 | Contents                                           |
|----------------------|----------------------------------------------------|
| `nat.go`             | unsigned magnitude arithmetic (add, sub, mul, divmod, pow) |
| `int.go`             | public signed `Int` type, parsing, printing, errors |
| `internal/query`     | the `<a> <op> <b>` query language evaluator         |
| `cmd/bigint`         | the command-line tool                               |

## Build

Requires Go 1.27.1.

    ./build.sh            # produces bin/bigint (same as: go build -o bin/bigint ./cmd/bigint)
    go test ./...         # run the tests
    go test -bench . -run XXX

## Command-line usage

`bigint` reads queries from standard input, one per line, and writes one result
line per query. `./run.sh` runs the built binary.

    $ printf '12 + 30\n-7 / 2\n-7 %% 2\n2 ^ 10\n007 cmp 7\n1 / 0\n' | ./run.sh
    42
    -3
    -1
    1024
    0
    error

Each line is `<a> <op> <b>` with `op` one of `+ - * / % ^ cmp`; operands match
`-?[0-9]+` (leading zeros and `-0` are accepted). Results are canonical decimal
(no leading zeros, never `-0`); `cmp` prints `-1`, `0` or `1`. Division or
remainder by zero and a negative exponent print `error`. `/` truncates toward
zero and `%` takes the sign of the dividend. `x ^ 0` is `1`, including `0 ^ 0`.
A malformed line makes the tool exit with status 1 and a message on stderr.

## Library usage

```go
package main

import (
	"fmt"

	"example.com/bigint"
)

func main() {
	a := bigint.MustParse("-123456789012345678901234567890")
	b := bigint.MustParse("987654321098765432109876543210")
	fmt.Println(a.Mul(b)) // -121932631137021795226185032733622923332237463801111263526900

	q, r, err := bigint.FromInt64(-7).QuoRem(bigint.FromInt64(2))
	fmt.Println(q, r, err) // -3 -1 <nil>

	if _, err := a.Quo(bigint.FromInt64(0)); err == bigint.ErrDivByZero {
		fmt.Println("division by zero")
	}

	p, _ := bigint.FromInt64(2).Exp(bigint.FromInt64(100))
	fmt.Println(p) // 1267650600228229401496703205376
}
```

`*bigint.Int` values are immutable: every method returns a new value. API:
`Parse`, `MustParse`, `FromInt64`, `String`, `Sign`, `Cmp`, `Neg`, `Abs`, `Add`,
`Sub`, `Mul`, `Quo`, `Rem`, `QuoRem`, `Exp`; errors `ErrSyntax`,
`ErrDivByZero`, `ErrNegativeExponent`, `ErrExponentTooLarge`. See `go doc`.
