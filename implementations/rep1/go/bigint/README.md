# bigint

Signed arbitrary-precision integer arithmetic in pure Go, written from scratch
(no `math/big`), plus a small command-line tool that evaluates one query per
line. Designed for decimal integers with tens of thousands of digits.

## Design

* `Int` = sign + magnitude; the magnitude is a little-endian slice of `uint32`
  limbs in base 10^9, so parsing and printing decimal text are linear.
* Add / subtract / compare: linear.
* Multiply: schoolbook, O(n·m).
* Divide / remainder: Knuth's Algorithm D (quotient and remainder together),
  C semantics (truncate toward zero, remainder takes the sign of the dividend).
* Power: binary exponentiation.

| File          | Responsibility                                  |
|---------------|-------------------------------------------------|
| `nat.go`      | unsigned magnitude: add, sub, compare, limb ops |
| `mul.go`      | schoolbook multiplication                       |
| `div.go`      | Knuth Algorithm D                               |
| `pow.go`      | square-and-multiply                             |
| `convert.go`  | `Parse`, `String`, `Append`                     |
| `int.go`      | signed `Int` and the public arithmetic API      |
| `errors.go`   | exported error values                           |
| `cmd/bigint/` | the command-line tool                           |

## Build

Requires Go 1.27 or later.

```sh
./build.sh          # produces bin/bigint
go test ./...       # run the tests
```

## Command-line usage

Queries are read from standard input, one per line, as `<a> <op> <b>`, where
`op` is `+ - * / % ^ cmp`. One result is printed per line. Division or
remainder by zero and negative exponents print `error`.

```sh
$ printf '12 + 30\n-7 / 2\n-7 %% 2\n2 ^ 100\n007 cmp -0\n1 / 0\n' | ./run.sh
42
-3
-1
1267650600228229401496703205376
1
error
```

Operands match `-?[0-9]+`; leading zeros and `-0` are accepted. Results are
canonical (no leading zeros, never `-0`). `cmp` prints `-1`, `0` or `1`.

## Library usage

```go
package main

import (
	"fmt"

	"github.com/peteralexander/bigint"
)

func main() {
	a := bigint.MustParse("-123456789012345678901234567890")
	b, err := bigint.Parse("987654321098765432109876543210")
	if err != nil {
		panic(err)
	}
	fmt.Println(a.Mul(b)) // -121932631137021795226185032733622923332237463801111263526900

	q, r, err := bigint.New(-7).QuoRem(bigint.New(2))
	fmt.Println(q, r, err) // -3 -1 <nil>

	p, _ := bigint.New(2).Exp(bigint.New(100))
	fmt.Println(p) // 1267650600228229401496703205376
}
```

`Int` values are immutable; every method returns a new value. API: `New`,
`Parse`, `MustParse`, `Add`, `Sub`, `Mul`, `QuoRem`, `Quo`, `Rem`, `Exp`, `Cmp`,
`Sign`, `Neg`, `Abs`, `String`, `Append`. Errors: `ErrDivisionByZero`,
`ErrNegativeExponent`, `ErrExponentTooLarge`, `ErrSyntax`.
