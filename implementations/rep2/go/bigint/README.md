# bigint

Signed arbitrary-precision integer arithmetic in pure Go, written from scratch
on the standard library only (no `math/big`). It provides a small reusable
library and a command-line tool that evaluates one query per line.

- Magnitudes are little-endian slices of base-10⁹ limbs, so parsing and
  printing decimal text are linear in the number of digits.
- Addition, subtraction and comparison are linear; multiplication is
  schoolbook O(n·m); division is Knuth's Algorithm D; exponentiation is
  left-to-right binary exponentiation.
- Division uses C semantics: the quotient truncates toward zero and the
  remainder takes the sign of the dividend.

## Layout

| Path | Contents |
|------|----------|
| `doc.go`, `int.go` | public `Int` type: sign, comparison, add, sub, mul, quo/rem, pow |
| `nat.go` | unsigned limb-level algorithms (internal) |
| `convert.go` | decimal parsing and formatting |
| `errors.go` | exported error values |
| `cmd/bigint` | the command-line tool (`main.go` I/O, `process.go` query evaluation) |
| `build.sh`, `run.sh` | build the tool into `bin/bigint`, and run it |

## Building

Requires Go 1.27 or newer.

```
./build.sh          # or: go build -o bin/bigint ./cmd/bigint
go test ./...       # unit tests
```

## Command-line usage

`bigint` reads all of standard input and writes one line per query to standard
output (`./run.sh < queries.txt`). Each query is `<a> <op> <b>`, separated by
single spaces, where operands match `-?[0-9]+` (leading zeros and `-0` are
fine) and `op` is one of `+ - * / % ^ cmp`.

```
$ printf '12 + 30\n-7 / 2\n-7 %% 2\n2 ^ 100\n007 cmp 7\n1 / 0\n' | ./run.sh
42
-3
-1
1267650600228229401496703205376
0
error
```

Results are in canonical decimal form (no leading zeros, never `-0`). `cmp`
prints `-1`, `0` or `1`. Division or remainder by zero and a negative exponent
print `error`. `0 ^ 0` is `1`.

## Library usage

```go
package main

import (
	"fmt"

	"github.com/peteralexander/bigint"
)

func main() {
	a := bigint.MustParse("-123456789012345678901234567890")
	b, _ := bigint.Parse("987654321098765432109876543210")

	fmt.Println(a.Mul(b)) // -121932631137021795226185032733622923332237463801111263526900

	q, r, err := a.QuoRem(bigint.FromInt64(1000))
	fmt.Println(q, r, err) // -123456789012345678901234567 -890 <nil>

	p, _ := bigint.FromInt64(2).Pow(bigint.FromInt64(100))
	fmt.Println(p, p.Cmp(a)) // 1267650600228229401496703205376 1

	_, err = a.Quo(bigint.Int{})
	fmt.Println(err == bigint.ErrDivisionByZero) // true
}
```

`Int` values are immutable, and the zero value is 0. The API: `Parse`,
`ParseBytes`, `MustParse`, `FromInt64`, `FromUint64`, `String`, `AppendTo`,
`Sign`, `IsZero`, `Neg`, `Abs`, `Cmp`, `Add`, `Sub`, `Mul`, `QuoRem`, `Quo`,
`Rem` and `Pow`. See `go doc` for details.

## Performance

Multiplying two 50,000-digit numbers takes a few tens of milliseconds;
dividing a 50,000-digit number by a 25,000-digit one is similar.
