# linalg

A small dense real linear algebra library for D, with a command-line driver
that runs a script of matrix operations on [Matrix Market](https://math.nist.gov/MatrixMarket/)
files. Everything is written from scratch on the D standard library — no BLAS,
LAPACK or other linear algebra code.

Operations: `add`, `mul`, `transpose`, LU with partial pivoting (`lu`, `det`,
`inv`, `solve`), Householder QR (`qr`, `lstsq`), Cholesky (`chol`), cyclic
Jacobi symmetric eigendecomposition (`eig`), one-sided Jacobi SVD (`svd`,
`cond`), and the 1, ∞ and Frobenius norms. The algorithms are the classical
dense ones, with every sum accumulated in a fixed, documented order, so results
are reproducible bit for bit. Eigen/singular vectors are sign-normalised and
sorted so that results are unique.

## Building

Requires LDC and dub.

```sh
dub build -b release --compiler=ldc2     # builds ./linalg
./build.sh                               # same thing, from any directory
```

The build passes `--fp-contract=off` to LDC (see `dub.sdl`) so that the
compiler never fuses multiply-adds and the rounding follows the written order
of operations.

## Command line

```sh
./run.sh <input directory> <output directory>
```

The input directory holds `commands.txt` and the matrix files it names. Each
non-blank, non-`#` line is one command, `op file [file]`; commands are numbered
from 1. Results go to the (existing, empty) output directory as
`NNN_<suffix>.mtx` in Matrix Market `array real general` form with `%.10e`
values, e.g. `003_lu_L.mtx`. A command that cannot be carried out writes
`NNN_error.txt` holding one of `dimension_mismatch`, `not_square`,
`not_symmetric`, `not_positive_definite`, `singular`, and the rest of the
script still runs. The exit status is 0.

| command | arguments | result files |
|---|---|---|
| `add`, `mul` | `A B` | `add`, `mul` |
| `transpose` | `A` | `transpose` |
| `lu` | `A` | `lu_P`, `lu_L`, `lu_U` |
| `det`, `norm1`, `norminf`, `normfro`, `cond` | `A` | same name, 1x1 |
| `inv` | `A` | `inv` |
| `solve`, `lstsq` | `A B` | `solve`, `lstsq` |
| `qr` | `A` | `qr_Q`, `qr_R` |
| `chol` | `A` | `chol_L` |
| `eig` | `A` | `eig_w`, `eig_V` |
| `svd` | `A` | `svd_U`, `svd_S`, `svd_V` |

## Library

The package is split by responsibility:

| module | contents |
|---|---|
| `linalg.matrix` | the dense row-major `Matrix` type |
| `linalg.ops` | `add`, `mul`, `transpose`, `norm1`, `normInf`, `normFro`, `isSymmetric` |
| `linalg.lu` | `luDecompose`, `luFactor`, `determinant`, `solve`, `inverse` |
| `linalg.qr` | `qrDecompose`, `leastSquares` |
| `linalg.cholesky` | `cholesky` |
| `linalg.eigen` | `symmetricEigen` |
| `linalg.svd` | `svd`, `condition` |
| `linalg.ordering` | sort order and sign conventions for vectors |
| `linalg.mmio` | Matrix Market parsing and formatting |
| `linalg.script` | the command-script driver used by the CLI |
| `linalg.errors` | `LinAlgException` and `ErrorCode` |

`import linalg;` pulls in all of them. Failures are `LinAlgException`s whose
`code` is the `ErrorCode`.

```d
import std.stdio;
import linalg;

void main()
{
    auto a = Matrix.fromRows([[4.0, 3.0], [6.0, 3.0]]);
    auto b = Matrix.fromRows([[10.0], [12.0]]);

    auto x = solve(a, b);                  // A x = b
    writeln(x[0, 0], " ", x[1, 0]);        // 1 2

    writeln(determinant(a));               // -6

    auto e = symmetricEigen(Matrix.fromRows([[2.0, 1.0], [1.0, 3.0]]));
    writeln(e.w);                          // ascending eigenvalues

    try
        cholesky(a);                       // not symmetric
    catch (LinAlgException err)
        writeln(err.code);                 // notSymmetric
}
```

To depend on the library only (without the executable configuration), use
`subConfiguration "linalg" "library"` in your `dub.sdl`.

## Tests

The tests are D `unittest` blocks next to the code they test, run by dub:

```sh
dub test --compiler=ldc2
```

The end-to-end suite lives in the parent repository: `python3 run_tests.py
linalg -- linalg/run.sh`.

## Layout

```
dub.sdl            package manifest (configurations: application, library)
build.sh run.sh    build and run wrappers
source/app.d       command-line entry point
source/linalg/     the library
```
