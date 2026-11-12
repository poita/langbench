# linalg

A dense real linear algebra library in pure Rust (standard library only —
no BLAS, LAPACK or other numerical crates), plus a command-line driver that
runs a script of matrix operations over [Matrix Market](https://math.nist.gov/MatrixMarket/)
files.

Operations: `add`, `mul`, `transpose`, `lu` (partial pivoting), `det`, `inv`,
`solve`, `qr` (Householder), `chol`, `eig` (symmetric, cyclic Jacobi), `svd`
(one-sided Jacobi), `lstsq`, `norm1`, `norminf`, `normfro`, `cond`.

All algorithms are the classical dense ones; every sum is a single running sum
in natural index order, so results are deterministic.

## Build

```sh
cargo build --release      # or ./build.sh
cargo test                 # unit, integration and doc tests
```

## Command-line usage

```sh
linalg <input directory> <output directory>   # or ./run.sh <in> <out>
```

The input directory holds `commands.txt` and the matrix files it names. Each
non-blank, non-`#` line is a command: an operation followed by its matrix file
names, e.g.

```
# commands.txt
add a.mtx b.mtx
det a.mtx
chol s.mtx
```

Matrix files are Matrix Market `coordinate` or `array` files with `real`,
`integer` or `pattern` fields and `general`, `symmetric` or `skew-symmetric`
symmetry. Command *N* writes `NNN_<suffix>.mtx` files (e.g. `002_det.mtx`,
`004_lu_P.mtx`, `004_lu_L.mtx`, `004_lu_U.mtx`) into the output directory in
`array real general` form with `%.10e` values. A command that cannot be carried
out (`dimension_mismatch`, `not_square`, `not_symmetric`,
`not_positive_definite`, `singular`) writes `NNN_error.txt` holding the code
instead; the rest of the script still runs and the exit status is 0.

## Library usage

```rust
use linalg::{lu, qr, svd, Matrix};

let a = Matrix::from_rows(&[vec![1.0, 2.0], vec![3.0, 4.0]]);
let b = Matrix::from_rows(&[vec![5.0], vec![6.0]]);

// Solve A x = b via LU with partial pivoting.
let x = lu::solve(&a, &b).unwrap();
assert!((x.get(1, 0) - 4.5).abs() < 1e-12);

// Householder QR with a non-negative diagonal on R.
let f = qr::qr(&a).unwrap();
assert!(f.r.get(0, 0) >= 0.0);

// Singular values, descending.
let s = svd::svd(&a).s;
assert!(s[0] >= s[1]);

// Failures are typed.
let rect = Matrix::zeros(2, 3);
assert_eq!(lu::det(&rect).unwrap_err().code(), "not_square");
```

## Layout

| module | contents |
|---|---|
| `matrix` | dense `Matrix`, elementwise ops, `mul`, `transpose`, norms |
| `lu` | `Lu` factorisation, `det`, `solve`, `inverse` |
| `qr` | Householder `qr`, `lstsq` |
| `chol` | `cholesky` |
| `eig` | `eigh` (symmetric Jacobi) |
| `svd` | `svd` (one-sided Jacobi), `cond` |
| `signs` | eigen/singular vector sign convention |
| `mmio` | Matrix Market `parse` and `write` |
| `script` | script parsing and the directory driver used by the CLI |
