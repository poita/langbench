# bigint

Signed arbitrary-precision integer arithmetic in pure Go, written from scratch
(no `math/big`, standard library only), plus a small command-line calculator
built on top of it.

Numbers are stored as a sign and a little-endian slice of base-10⁹ limbs, so
parsing and printing decimal text is linear in the number of digits.
Addition, subtraction and comparison are linear; multiplication is schoolbook
O(n·m); division is Knuth's Algorithm D; exponentiation is left-to-right binary
exponentiation. This is comfortably fast for operands of tens of thousands of
digits.

## Layout

| Path                      | Contents                                              |
|---------------------------|-------------------------------------------------------|
| `nat.go`                  | magnitude (unsigned) algorithms: add, sub, mul, divide, pow |
| `int.go`                  | the public signed `Int` type and its operations       |
| `convert.go`              | decimal parsing and formatting                        |
| `internal/queries`        | the `<a> <op> <b>` query evaluator used by the CLI    |
| `cmd/bigint`              | the command-line tool                                 |
| `*_test.go`               | unit tests and a runnable example                     |

## Build

Requires Go 1.27 or newer.

```sh
./build.sh          # produces bin/bigint
go test ./...       # runs the unit tests
```

## Command-line usage

The tool reads queries from standard input, one per line, and prints one result
line per query.

```sh
printf '12 + 30\n-7 / 2\n2 ^ 100\n007 cmp 7\n' | ./run.sh
```

```
42
-3
1267650600228229401496703205376
0
```

Each line is `<a> <op> <b>`, with single spaces between tokens. Operands match
`-?[0-9]+` (leading zeros and `-0` are accepted). Operators:

| op    | result                                            |
|-------|---------------------------------------------------|
| `+` `-` `*` | sum, difference, product                    |
| `/`   | quotient truncated toward zero                    |
| `%`   | remainder with the sign of `a`                    |
| `^`   | `a` to the power `b`                              |
| `cmp` | `-1`, `0` or `1`                                  |

Results are canonical decimal (no leading zeros, never `-0`). Division or
remainder by zero, and a negative exponent, print `error`.

## Library usage

```go
package main

import (
	"fmt"

	"github.com/example/bigint"
)

func main() {
	a := bigint.MustParse("123456789012345678901234567890")
	b := bigint.FromInt64(-987654321)

	fmt.Println(a.Add(b)) // 123456789012345678900246913569
	fmt.Println(a.Mul(b)) // -121932631124828532112482853211126352690

	q, r, err := a.DivMod(b) // truncated division, remainder has the sign of a
	if err != nil {
		panic(err) // bigint.ErrDivideByZero
	}
	fmt.Println(q, r) // -124999998873437499901 574845669

	p, _ := bigint.FromInt64(2).Exp(bigint.FromInt64(100))
	fmt.Println(p) // 1267650600228229401496703205376
}
```

`Int` values are immutable, and the zero value is `0`. The API: `Parse`,
`ParseBytes`, `MustParse`, `FromInt64`, `FromUint64`, `String`, `AppendTo`,
`Sign`, `IsZero`, `Neg`, `Abs`, `Cmp`, `Add`, `Sub`, `Mul`, `Div`, `Rem`,
`DivMod`, `Exp`, `ExpUint64`. See `go doc` for details.
