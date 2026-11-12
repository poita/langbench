# linalg

A small dense real linear algebra library for Clojure, written from scratch in
plain `double` arithmetic (no BLAS, LAPACK or other numerical library), plus a
command-line driver that runs a script of matrix operations over
[Matrix Market](https://math.nist.gov/MatrixMarket/formats.html) files.

Operations: `add`, `mul`, `transpose`, the 1-, ∞- and Frobenius norms, LU with
partial pivoting, determinant, solve, inverse, Householder QR, least squares,
Cholesky, symmetric eigendecomposition (cyclic Jacobi), SVD (one-sided Jacobi)
and the 2-norm condition number. The algorithms are the classical dense ones,
with every sum accumulated in one running sum in a fixed order, so results are
deterministic and reproducible.

## Requirements and build

Clojure 1.12.6 (the `clojure` CLI, `deps.edn`) on Java 27.

```sh
./build.sh      # AOT-compiles the command-line tool into classes/
```

## Command-line use

```sh
./run.sh <input directory> <output directory>
```

The input directory holds `commands.txt` and the matrix files it names. Each
non-blank, non-`#` line of `commands.txt` is one command, e.g.

```
# a two by two example
add a.mtx b.mtx
det a.mtx
chol s.mtx
```

Commands are numbered from 1. Command `N` writes `NNN_<suffix>.mtx` files
(`001_add.mtx`, `003_chol_L.mtx`, `002_lu_P.mtx` …) in `array real general`
form with values printed like `printf("%.10e")`. A command that cannot be
carried out writes `NNN_error.txt` holding one of `dimension_mismatch`,
`not_square`, `not_symmetric`, `not_positive_definite`, `singular` and the rest
of the script still runs. The exit status is 0.

| command | arguments | result files |
|---|---|---|
| `add`, `mul`, `solve`, `lstsq` | `A B` | `NNN_<op>.mtx` |
| `transpose`, `inv` | `A` | `NNN_<op>.mtx` |
| `lu` | `A` | `_lu_P`, `_lu_L`, `_lu_U` |
| `qr` | `A` | `_qr_Q`, `_qr_R` |
| `chol` | `A` | `_chol_L` |
| `eig` | `A` | `_eig_w`, `_eig_V` |
| `svd` | `A` | `_svd_U`, `_svd_S`, `_svd_V` |
| `det`, `norm1`, `norminf`, `normfro`, `cond` | `A` | 1x1 `NNN_<op>.mtx` |

## Library

| namespace | responsibility |
|---|---|
| `linalg.core` | the public API: one function per operation, plus file I/O |
| `linalg.matrix` | the dense `Matrix` record, `add`, `mul`, `transpose`, norms |
| `linalg.lu` | LU, `det`, `solve`, `inverse` |
| `linalg.qr` | Householder QR, `lstsq` |
| `linalg.chol` | Cholesky |
| `linalg.eig` | symmetric eigendecomposition |
| `linalg.svd` | SVD, `cond-number` |
| `linalg.mmio` | Matrix Market reader and writer |
| `linalg.sign`, `linalg.jacobi` | helpers shared by `eig` and `svd` |
| `linalg.error` | error codes |
| `linalg.cli` | the command-line driver |

```clojure
(require '[linalg.core :as la]
         '[linalg.matrix :as m])

(def a (m/from-rows [[4 2] [2 5]]))

(m/to-rows (:L (la/lu a)))            ;=> [[1.0 0.0] [0.5 1.0]]
(m/to-rows (la/chol a))               ;=> [[2.0 0.0] [1.0 2.0]]
(la/det a)                            ;=> 16.0
(m/to-rows (la/solve a (m/from-rows [[2] [3]])))

(let [{:keys [w V]} (la/eig a)]       ; ascending eigenvalues, unit eigenvectors
  (m/to-rows w))

(la/cond-number a)

;; failures are ex-info with a :linalg/error code
(try (la/chol (m/from-rows [[1 2] [2 1]]))
     (catch clojure.lang.ExceptionInfo e (:linalg/error (ex-data e))))
;=> :not-positive-definite
```

Matrices are `linalg.matrix/Matrix` records (`rows`, `cols`, and a row-major
`double[]` `data`) and are never mutated by the library. Matrix files are read
and written with `la/read-matrix` and `la/write-matrix`.

## Tests

```sh
clojure -X:test        # Cognitect test-runner; unit tests and test.check properties
```

The properties check residuals (`P A = L U`, `Q R = A`, `L Lᵀ = A`,
`A V = V diag(w)`, `U diag(s) Vᵀ = A`, …) on random matrices.
