# linalg

A dense real linear algebra library in Go, written from scratch on the
standard library only (no BLAS/LAPACK-style routines), plus a command-line
driver that runs a script of matrix operations over Matrix Market files.

Supported operations: `add`, `mul`, `transpose`, LU with partial pivoting,
`det`, `inv`, `solve`, Householder QR, `lstsq`, Cholesky, symmetric
eigendecomposition (cyclic Jacobi), thin SVD (one-sided Jacobi), `cond`, and
the 1, ∞ and Frobenius norms. Every algorithm uses a fixed, documented
operation order, so results are reproducible.

## Layout

| path | responsibility |
|---|---|
| `matrix.go`, `ops.go` | `Matrix` (flat row-major), add/mul/transpose, norms |
| `lu.go` | LU, `Det`, `Solve`, `Inverse` |
| `qr.go` | Householder QR, `LeastSquares` |
| `chol.go` | Cholesky |
| `eig.go` | symmetric Jacobi eigensolver, `SignNormalize` |
| `svd.go` | one-sided Jacobi SVD, `SingularValues`, `Cond` |
| `errors.go` | sentinel errors (`ErrSingular`, …) |
| `mmio/` | Matrix Market reader / writer |
| `internal/driver/` | script parsing and command dispatch |
| `cmd/linalg/` | the command-line tool |

## Build

Requires Go 1.27.1.

```sh
./build.sh          # produces bin/linalg
go test ./...       # unit tests
```

## Command line

```sh
./run.sh <input directory> <output directory>
# or: bin/linalg <input directory> <output directory>
```

The input directory holds `commands.txt` (one command per line; blank lines
and `#` comments are skipped and not counted) and the Matrix Market files it
names, e.g.

```
add a.mtx b.mtx
det a.mtx
svd m.mtx
```

Result `k` is written to `NNN_<suffix>.mtx` (`NNN` = zero-padded command
number, e.g. `001_add.mtx`, `003_lu_P.mtx`, `003_lu_L.mtx`, `003_lu_U.mtx`) in
`array real general` form with values printed as `%.10e`. A command that
cannot be carried out writes `NNN_error.txt` containing one of
`dimension_mismatch`, `not_square`, `not_symmetric`, `not_positive_definite`
or `singular`, and the program still exits 0. (Unreadable matrices or unknown
operations, which the format does not define, write `invalid_input` and a note
on stderr.) Nothing is read from stdin or printed to stdout.

The full format is specified in `problems/linalg/SPEC.md`.

## Library example

```go
package main

import (
	"errors"
	"fmt"

	"linalg"
	"linalg/mmio"
)

func main() {
	a, _ := linalg.FromRows([][]float64{{4, 2}, {2, 5}})
	b, _ := linalg.FromRows([][]float64{{1}, {2}})

	x, err := linalg.Solve(a, b)
	if err != nil {
		panic(err)
	}
	fmt.Println(x.Data) // [0.0625 0.375]

	if _, err := linalg.Cholesky(linalg.New(2, 3)); errors.Is(err, linalg.ErrNotSquare) {
		fmt.Println("not square:", err)
	}

	e, _ := linalg.EigSym(a)
	fmt.Println(e.Values)

	fmt.Print(string(mmio.Format(x))) // Matrix Market text
}
```

## Notes

- Go may fuse `x*y + z` into a single fused multiply-add on some
  architectures (e.g. arm64); this changes results only in the last bit.
- Jacobi methods run at most 60 sweeps, per the specification.
