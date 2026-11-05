# bigint

Signed arbitrary-precision integer arithmetic in pure Go, written from scratch
with no dependencies beyond the standard library (and without `math/big`).
It provides a small reusable library and a command-line tool that evaluates
batches of queries on integers with tens of thousands of digits.

## Design

A value is a sign and a magnitude; the magnitude is a little-endian slice of
base-10⁹ limbs in `uint32`, with 64-bit intermediates. The decimal base makes
parsing and printing linear. Algorithms are the classical quadratic ones:
linear add/subtract/compare, schoolbook multiplication, short division and
Knuth's Algorithm D for long division, and left-to-right binary
exponentiation.

Layout:

| Path | Contents |
|------|----------|
| `doc.go`, `int.go` | public `Int` type and its arithmetic API |
| `nat.go` | unsigned limb-level algorithms (add, sub, mul, divide, pow) |
| `convert.go` | decimal parsing and formatting |
| `cmd/bigint` | the command-line tool |
| `*_test.go` | unit tests and a runnable example |

## Build

Requires Go 1.27 or newer.

    ./build.sh          # produces bin/bigint (equivalent to: go build -o bin/bigint ./cmd/bigint)
    go test ./...       # unit tests

## CLI

`bigint` reads queries from standard input, one per line, in the form
`<a> <op> <b>` where `op` is one of `+ - * / % ^ cmp`, and writes one result
line per query. Operands match `-?[0-9]+` (leading zeros and `-0` allowed).

    $ printf '12 + 30\n-7 / 2\n-7 %% 2\n2 ^ 10\n007 cmp 7\n1 / 0\n' | ./run.sh
    42
    -3
    -1
    1024
    0
    error

- `/` truncates toward zero; `%` takes the sign of the dividend.
- `cmp` prints `-1`, `0` or `1`.
- Division or remainder by zero, and a negative exponent, print `error`.
- `0 ^ 0 = 1`; zero is always printed as `0`, never `-0`.

## Library

    import "github.com/example/bigint"

    a, _ := bigint.Parse("-123456789012345678901234567890")
    b, _ := bigint.Parse("987654321098765432109876543210")
    fmt.Println(a.Mul(b))               // -121932631137021795226185032733622923332237463801111263526900

    q, r, _ := bigint.NewInt(-7).QuoRem(bigint.NewInt(2))
    fmt.Println(q, r)                   // -3 -1

    p, _ := bigint.NewInt(2).Exp(bigint.NewInt(100))
    fmt.Println(p)                      // 1267650600228229401496703205376

    _, err := bigint.NewInt(1).Quo(bigint.NewInt(0))
    fmt.Println(err)                    // bigint: division by zero

`Int` values are immutable: methods (`Add`, `Sub`, `Mul`, `Quo`, `Rem`,
`QuoRem`, `Pow`, `Exp`, `Neg`, `Abs`, `Cmp`, `Sign`, `String`, `AppendTo`)
return new values and never modify their operands. See the package
documentation (`go doc github.com/example/bigint`) for details.
