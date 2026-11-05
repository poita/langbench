# linalg

A small dense real linear-algebra library for D, plus a command-line driver
that runs a script of matrix operations over [Matrix Market](https://math.nist.gov/MatrixMarket/formats.html)
files. Everything is written from scratch on top of Phobos/druntime — no BLAS,
LAPACK or other numerical library.

Operations: `add`, `mul`, `transpose`, LU with partial pivoting (`lu`, `det`,
`inv`, `solve`), Householder QR (`qr`, `lstsq`), Cholesky (`chol`), symmetric
eigendecomposition by cyclic Jacobi (`eig`), SVD by one-sided Jacobi (`svd`,
`cond`), and the 1-, ∞- and Frobenius norms. The floating-point evaluation
order of every algorithm is fixed, so results are reproducible.

## Layout

```
dub.json              package manifest (configurations: cli, library, unittest)
build.sh, run.sh      build the CLI / run it from any directory
source/app.d          the command-line tool (thin wrapper)
source/linalg/        the library
    package.d         `import linalg;` re-exports everything
    matrix.d          Matrix type, add / multiply / transpose / norms
    lu.d              LU, determinant, solve, inverse
    qr.d              Householder QR, least squares
    cholesky.d        Cholesky
    eigen.d           symmetric Jacobi eigensolver
    svd.d             one-sided Jacobi SVD, singular values, condition number
    signs.d           sign normalisation of eigen/singular vectors
    mmio.d            Matrix Market reader and writer
    script.d          command-script parser and runner
    errors.d          LinalgException / ErrorCode
tests/                unit tests (separate from the library sources)
```

## Building

Requires LDC and dub.

```sh
./build.sh                                # or: dub build -b release --compiler=ldc2
dub test --compiler=ldc2                  # unit tests
```

The executable is `bin/linalg`.

## Command-line usage

```
linalg <input directory> <output directory>
```

The input directory holds `commands.txt` and the matrix files it names. One
command per line (`#` comments and blank lines are ignored):

```
add A B        mul A B        transpose A     lu A         det A
inv A          solve A B      qr A            chol A       eig A
svd A          lstsq A B      norm1 A         norminf A    normfro A
cond A
```

Matrices are Matrix Market files (`coordinate` or `array`; `real`, `integer`
or `pattern`; `general`, `symmetric` or `skew-symmetric`). Each command *N*
writes `NNN_<suffix>.mtx` files (e.g. `003_lu_L.mtx`) in `array real general`
form with `%.10e` values, column-major. A command that cannot be carried out
(`dimension_mismatch`, `not_square`, `not_symmetric`, `not_positive_definite`,
`singular`) writes `NNN_error.txt` containing the code, and the script goes on.
The program always exits 0 once it has started; nothing is printed to stdout.

```sh
$ cat in/commands.txt
add a.mtx b.mtx
det a.mtx
chol s.mtx
$ ./run.sh in out && ls out
001_add.mtx  002_det.mtx  003_chol_L.mtx
```

## Library example

```d
import std.stdio;
import linalg;

void main()
{
    auto a = Matrix.fromRows([[4.0, 2.0], [2.0, 5.0]]);
    auto b = Matrix.fromRows([[1.0], [2.0]]);

    auto x = solve(a, b);                 // A x = b via LU
    writeln(x.data);

    auto l = cholesky(a);                 // A = L Lᵀ
    auto e = symmetricEigen(a);           // ascending eigenvalues, e.V columns
    auto s = svd(a);                      // s.U, s.s, s.V
    writeln(e.w, " ", s.s, " cond=", conditionNumber(a));

    try
        inverse(Matrix.fromRows([[1.0, 2.0], [2.0, 4.0]]));
    catch (LinalgException ex)
        writeln(ex.code);                 // ErrorCode.singular

    auto m = parseMatrixMarket("%%MatrixMarket matrix array real general\n1 1\n2.5\n");
    write(formatMatrixMarket(m));         // `%.10e` array output
}
```

Add it to a dub project with `"dependencies": { "linalg": { "path": "../linalg" } }`
and select the `library` configuration (`"subConfigurations": { "linalg": "library" }`).

## Notes on conventions

* Factorisations never modify their inputs; they work on copies.
* `lu`/`det` use first-maximum pivoting; `qr` forces a non-negative diagonal
  on `R`; eigenvectors and left singular vectors are sign-normalised so the
  largest-magnitude component (first on ties) is positive.
* `eig` and `svd` use Jacobi sweeps (at most 60), `O(n³)` per sweep.
