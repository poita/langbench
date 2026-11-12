# linalg

A dense real linear algebra library in pure Python (standard library only),
with a command-line driver that runs a script of matrix operations over
Matrix Market files.

The algorithms are written from scratch, with the floating-point summation
order fixed so results are reproducible: LU with partial pivoting, Householder
QR, Cholesky, cyclic Jacobi eigendecomposition, one-sided Jacobi SVD, least
squares, determinant, inverse, condition number and the usual norms.  No
BLAS/LAPACK/numpy is used.

Requires Python 3.14.

## Build

There is nothing to compile.  `./build.sh` byte-compiles the package; the
project metadata lives in `pyproject.toml` (setuptools, `src/` layout).

```
./build.sh
```

## Command-line use

```
./run.sh <input directory> <output directory>
# or: PYTHONPATH=src python3 -m linalg <input directory> <output directory>
```

The input directory holds `commands.txt` and the matrix files it names (Matrix
Market `coordinate`/`array`, `real`/`integer`/`pattern`,
`general`/`symmetric`/`skew-symmetric`).  Each non-blank, non-`#` line is a
command, numbered from 1:

| command | arguments | result files |
|---|---|---|
| `add A B`, `mul A B`, `solve A B`, `lstsq A B` | two matrices | `NNN_<op>.mtx` |
| `transpose A`, `inv A` | one matrix | `NNN_<op>.mtx` |
| `lu A` | square | `NNN_lu_P.mtx`, `_L`, `_U` |
| `qr A` | `m >= n` | `NNN_qr_Q.mtx`, `NNN_qr_R.mtx` |
| `chol A` | SPD | `NNN_chol_L.mtx` |
| `eig A` | symmetric | `NNN_eig_w.mtx`, `NNN_eig_V.mtx` |
| `svd A` | any | `NNN_svd_U.mtx`, `_S`, `_V` |
| `det A`, `norm1 A`, `norminf A`, `normfro A`, `cond A` | one matrix | 1x1 `NNN_<op>.mtx` |

Results are Matrix Market `array real general` files with values written as
`%.10e`.  A command that cannot be carried out writes `NNN_error.txt`
containing one of `dimension_mismatch`, `not_square`, `not_symmetric`,
`not_positive_definite`, `singular`; the rest of the script still runs and the
exit status is 0.

## Library use

```python
from linalg import Matrix, solve, lu_factor, eigh, svd, cond, read_matrix, Singular

a = Matrix([[4, 2], [2, 5]])
b = Matrix([[1], [2]])

x = solve(a, b)                 # A X = B
f = lu_factor(a)                # P A = L U
print(f.P, f.L, f.U)

w, v = eigh(a)                  # ascending eigenvalues, sign-normalised vectors
u, s, vt_cols = svd(a)          # A = U diag(s) Vᵀ
print(cond(a))

try:
    solve(Matrix([[1, 2], [2, 4]]), b)
except Singular:
    print("singular")

m = read_matrix("some_file.mtx")   # dense Matrix from any Matrix Market form
```

Public names are listed in `linalg/__init__.py`.  Modules:

| module | responsibility |
|---|---|
| `matrix` | the dense `Matrix` type |
| `mmio` | Matrix Market parsing and output formatting |
| `arithmetic`, `norms` | `add`, `mul`, `transpose`; `norm1`, `norminf`, `normfro` |
| `lu` | LU, `det`, `solve`, `inv` |
| `householder` | `qr`, `lstsq` |
| `llt` | `cholesky` |
| `eigen` | `eigh` (cyclic Jacobi) |
| `jacobi_svd` | `svd`, `cond` (one-sided Jacobi) |
| `errors` | `LinalgError` and its subclasses |
| `cli` | the command-line driver |

Matrices are at most a few hundred on a side in practice; everything is
classical O(n³) dense code in pure Python.

## Tests

```
python3 -m pytest
```
