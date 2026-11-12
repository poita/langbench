# linalg

A small dense real linear-algebra library in C++17 with a command-line driver.
Everything is implemented from scratch on `double` with the standard library
only — no BLAS/LAPACK/Eigen. The algorithms and their summation orders follow
the specification exactly, so results are reproducible to the last rounding.

Provided operations: `add`, `multiply`, `transpose`, the 1/∞/Frobenius norms,
LU with partial pivoting (`lu_factor`, `determinant`, `solve`, `inverse`),
Householder QR and least squares, Cholesky, symmetric eigendecomposition
(cyclic Jacobi), and SVD (one-sided Jacobi) with the 2-norm condition number.
Matrix Market input (coordinate/array, real/integer/pattern,
general/symmetric/skew-symmetric) and `array real general` output are included.

## Layout

| path | contents |
|---|---|
| `include/linalg/` | public headers (`linalg.hpp` includes all) |
| `src/` | library implementation, one module per header |
| `cli/` | `driver.{hpp,cpp}` (script runner, also used by the tests) and `main.cpp` |
| `tests/` | GoogleTest suite |

Modules: `matrix` (type, add/multiply/transpose/norms), `matrix_market`
(I/O), `lu`, `qr` (QR + lstsq), `cholesky`, `eigen`, `svd` (+ `cond`), `sign`
(eigen/singular-vector sign convention), `error` (`linalg::Error` with an
`ErrorCode`).

## Build

Requires a C++17 compiler, CMake ≥ 3.20 and (for tests) GoogleTest.

```sh
./build.sh                      # Release build into ./build
# or manually
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build          # run the unit tests
cmake -S . -B build -DLINALG_BUILD_TESTS=OFF   # skip the tests / GoogleTest
```

The library is compiled with `-ffp-contract=off`: the algorithms prescribe the
rounding of every intermediate, so the compiler must not fuse `a*b + c` into
an FMA (Clang does so by default on arm64). Optimisation flags are CMake's
normal Release ones.

## Command-line tool

```sh
./run.sh <input directory> <output directory>
```

`<input directory>/commands.txt` lists one command per line (blank lines and
`#` comments are ignored; only real commands are numbered):

```
add A B | mul A B | transpose A | lu A | det A | inv A | solve A B | qr A
chol A | eig A | svd A | lstsq A B | norm1 A | norminf A | normfro A | cond A
```

Arguments are Matrix Market files in the input directory. Command `N` writes
`NNN_<suffix>.mtx` result files (e.g. `003_lu_P.mtx`, `003_lu_L.mtx`,
`003_lu_U.mtx`) in `array real general` form with `%.10e` values, or a single
`NNN_error.txt` containing one of `dimension_mismatch`, `not_square`,
`not_symmetric`, `not_positive_definite`, `singular`. The exit status is 0
and nothing is printed on stdout.

## Library example

```cpp
#include <iostream>
#include "linalg/linalg.hpp"

int main() {
    using namespace linalg;
    const Matrix a = Matrix::from_rows({{4, 2}, {2, 5}});
    const Matrix b = Matrix::from_rows({{2}, {3}});

    Matrix x = solve(a, b);                    // LU solve of A x = b
    Matrix l = cholesky(a);                    // A = L Lᵀ
    SymmetricEigen e = eig_symmetric(a);       // ascending e.w, orthogonal e.V
    SVD f = svd(a);                            // A = U diag(s) Vᵀ
    std::cout << to_matrix_market(x)           // Matrix Market text
              << "cond = " << cond(a) << "\n";

    try {
        inverse(Matrix::from_rows({{1, 2}, {2, 4}}));
    } catch (const Error& err) {               // err.code() == ErrorCode::Singular
        std::cout << err.what() << "\n";       // "singular"
    }
}
```

Link against the `linalg` CMake target (`target_link_libraries(app PRIVATE linalg)`).
Failures that the specification names throw `linalg::Error`; malformed
Matrix Market text throws `linalg::ParseError`.
