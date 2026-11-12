# linalg

A dense real linear algebra library for Haskell with a small command line
driver. Everything is written from scratch on top of `base`, `array`,
`bytestring`, `containers`, `directory` and `filepath`: no BLAS, LAPACK or
other numerical package.

Algorithms (all classical, single running sums in a fixed order, so results
are reproducible bit for bit):

| Operation | Algorithm |
|---|---|
| `add`, `mul`, `transpose`, norms | direct loops |
| `lu`, `det`, `solve`, `inv` | Gaussian elimination with partial pivoting |
| `qr`, `lstsq` | Householder QR (thin), back substitution |
| `chol` | Cholesky, column by column |
| `eig` | cyclic Jacobi (symmetric matrices) |
| `svd`, `cond` | one-sided Jacobi |

## Building

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh            # or: cabal build exe:linalg
cabal test            # runs the hspec/QuickCheck suite
```

## Command line

```sh
./run.sh <input directory> <output directory>
```

The input directory holds `commands.txt` and the Matrix Market files it names.
Each non-blank, non-`#` line is one command (numbered from 1):

```
add A B     mul A B      transpose A   lu A      det A      inv A
solve A B   qr A         chol A        eig A     svd A      lstsq A B
norm1 A     norminf A    normfro A     cond A
```

For command number `N` the output directory receives `NNN_<suffix>.mtx` files
(for example `003_lu_P.mtx`, `003_lu_L.mtx`, `003_lu_U.mtx`), each in Matrix
Market `array real general` form with values printed as `%.10e`. A command that
cannot be carried out (`dimension_mismatch`, `not_square`, `not_symmetric`,
`not_positive_definite`, `singular`) writes `NNN_error.txt` containing the
error code instead, and the rest of the script still runs. The program exits
with status 0 and prints nothing on stdout.

Input matrices may be `coordinate` or `array`, `real`, `integer` or `pattern`,
`general`, `symmetric` or `skew-symmetric`; they are expanded to dense storage.

## Library

| Module | Contents |
|---|---|
| `Linalg.Matrix` | dense row-major `Matrix`, `add`, `mul`, `transpose`, `norm1`, `normInf`, `normFrobenius` |
| `Linalg.LU` | `lu`, `luFactor`, `luSolve`, `det`, `solve`, `inverse` |
| `Linalg.QR` | `qr`, `lstsq` |
| `Linalg.Cholesky` | `cholesky` |
| `Linalg.Eigen` | `eigSym` |
| `Linalg.SVD` | `svd`, `singularValues`, `cond` |
| `Linalg.MatrixMarket` | `parseMatrix`, `readMatrixFile`, `renderMatrix`, `writeMatrixFile` |
| `Linalg.Operation`, `Linalg.Runner` | the script language used by the CLI |
| `Linalg.Error` | `LinalgError` and its codes |
| `Linalg` | re-exports everything |

Functions that can fail return `Either LinalgError _`.

```haskell
import qualified Linalg.Matrix as M
import Linalg

main :: IO ()
main = do
  let a = M.fromLists [[4, 2], [2, 5]]
      b = M.fromLists [[2], [3]]

  -- Solve A x = b
  print (solve a b)                 -- Right (fromLists [[0.25],[0.5]])

  -- Cholesky: A = L L'
  print (cholesky a)                -- Right (fromLists [[2.0,0.0],[1.0,2.0]])

  -- Symmetric eigendecomposition
  case eigSym a of
    Right (Eigen w v) -> print w >> print v
    Left err          -> putStrLn (errorCode err)

  -- Singular values and condition number
  print (singularValues a)
  print (cond a)
```

Conventions worth knowing: `qr` returns a factorisation with a non-negative
diagonal on `R`; `eigSym` returns ascending eigenvalues and `svd` descending
singular values; eigenvector and singular-vector columns are sign-normalised so
that the entry of largest magnitude (smallest index on ties) is non-negative
(`Linalg.SignConvention`).

## Layout

```
linalg.cabal        package description (library, executable, test suite)
src/Linalg/*.hs     library modules
app/Main.hs         command line entry point
test/               hspec + QuickCheck tests
build.sh, run.sh    build and run helpers
```
