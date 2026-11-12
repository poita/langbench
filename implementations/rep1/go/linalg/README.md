# linalg

A dense real linear algebra library for Go, written from scratch on the
standard library only (no BLAS/LAPACK), plus a small command-line driver that
runs a script of matrix operations over Matrix Market files.

The library provides: `Add`, `Mul`, `Transpose`, the 1/∞/Frobenius norms, LU
with partial pivoting (`LU`, `Det`, `Solve`, `Inverse`), Householder QR and
least squares (`QR`, `LeastSquares`), `Cholesky`, the cyclic Jacobi symmetric
eigensolver (`SymEigen`), and the one-sided Jacobi `SVD` with `Cond`. All
algorithms are the classical O(n³) ones with every sum accumulated in a fixed,
documented order, and multiplications are never fused with additions, so
results are reproducible bit for bit across platforms.

## Layout

| path | contents |
|---|---|
| `*.go` (package `linalg`) | `Matrix` type, operations, factorisations, error values |
| `mmio/` | Matrix Market reader (coordinate/array, real/integer/pattern, general/symmetric/skew-symmetric) and writer |
| `internal/driver/` | script parsing, command dispatch, result file naming |
| `cmd/linalg/` | the command-line entry point |

## Build

Requires Go 1.27 or later.

```sh
./build.sh            # builds bin/linalg (go build -o bin/linalg ./cmd/linalg)
go test ./...         # run the tests
```

## Command-line use

```sh
./run.sh <input directory> <output directory>
```

The input directory holds `commands.txt` and the matrix files it names. Each
non-blank, non-`#` line is one command: an operation (`add mul transpose lu
det inv solve qr chol eig svd lstsq norm1 norminf normfro cond`) followed by
its matrix file names. For command number `N` (counting only command lines),
results are written to the output directory as `NNN_<suffix>.mtx` in Matrix
Market `array real general` form with `%.10e` values (for example
`001_lu_P.mtx`, `001_lu_L.mtx`, `001_lu_U.mtx`). A command that cannot be
carried out writes `NNN_error.txt` containing one of `dimension_mismatch`,
`not_square`, `not_symmetric`, `not_positive_definite` or `singular`, and the
run continues. The exit status is 0.

```
# commands.txt
det a.mtx
solve a.mtx b.mtx
```

## Library example

```go
package main

import (
	"fmt"
	"log"

	"example.com/linalg"
	"example.com/linalg/mmio"
)

func main() {
	a := linalg.FromRows([][]float64{{4, 2}, {2, 5}})

	l, err := linalg.Cholesky(a) // A = L Lᵀ
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(l.Data) // [2 0 1 2]

	w, v, _ := linalg.SymEigen(a) // ascending eigenvalues, sign-normalised vectors
	fmt.Println(w, v.Rows)

	if _, err := linalg.Inverse(linalg.New(2, 3)); err != nil {
		code, _ := linalg.ErrorCode(err)
		fmt.Println(code) // not_square
	}

	m, _ := mmio.ReadFile("a.mtx") // Matrix Market input
	_ = mmio.WriteFile("out.mtx", m)
}
```

See the package documentation (`go doc ./...`) for the full API.
