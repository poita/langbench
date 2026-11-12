# linalg — dense real linear algebra library

Build a dense real linear algebra library and a command line driver for it.
The driver reads a script of matrix operations and the matrices they refer to
from an input directory, and writes one result file per operation into an
output directory.

```
<program> <input directory> <output directory>
```

Nothing is read from stdin and nothing is printed to stdout; stderr is
ignored. The program must exit with status 0 and must not write anything
outside the output directory. The output directory already exists and is
empty. Text is UTF-8 with LF line endings.

Write the linear algebra yourself: don't use BLAS, LAPACK, Eigen, numpy or any
other linear-algebra routine from a library, the standard library or the
language.

## 1. The input directory

The input directory contains a file `commands.txt` and the matrix files it
names. Matrix files are named in `commands.txt` by their plain file name
(letters, digits, `_`, `-`, `.`; never a path with a separator).

### 1.1 commands.txt

One command per line. Before anything else, each line is stripped of leading
and trailing whitespace (spaces and tabs). A line that is then empty, or that
starts with `#`, is ignored completely and is **not** counted as a command.
Every other line is a command, split into tokens on runs of spaces and tabs.

Commands are numbered from 1 in the order they appear, counting only command
lines. The number is what names the result files, so ignored lines must not
advance the counter. A script holds at most 200 commands.

The first token is the operation, spelled in lower case and matched exactly
as written below. The tokens after it are the matrix arguments, one file name
each, and a command line holds the operation and exactly the number of
arguments the table gives, with nothing after them:

| command | arguments | meaning |
|---|---|---|
| `add A B` | two matrices of the same shape | `A + B` |
| `mul A B` | `m x k` and `k x n` | `A B` |
| `transpose A` | any | `Aᵀ` |
| `lu A` | `n x n` | `P A = L U` (partial pivoting) |
| `det A` | `n x n` | determinant |
| `inv A` | `n x n` | `A⁻¹` |
| `solve A B` | `n x n`, `n x k` | `X` with `A X = B` |
| `qr A` | `m x n`, `m >= n` | thin `A = Q R` |
| `chol A` | `n x n` symmetric positive definite | `A = L Lᵀ` |
| `eig A` | `n x n` symmetric | `A = V diag(w) Vᵀ` |
| `svd A` | `m x n` | thin `A = U diag(s) Vᵀ` |
| `lstsq A B` | `m x n` with `m >= n`, `m x k` | least squares `X` |
| `norm1 A` | any | `‖A‖₁` |
| `norminf A` | any | `‖A‖∞` |
| `normfro A` | any | `‖A‖F` |
| `cond A` | any | `σ_max / σ_min` |

Only these sixteen operations occur. Every argument names a file that exists
in the input directory and holds a well-formed matrix; the same file may be
named by several commands and by both arguments of one command. A matrix has
at least one row and one column; no dimension exceeds 500.

### 1.2 Matrix Market input files

Matrix files use the Matrix Market exchange format. The first line is the
banner:

```
%%MatrixMarket matrix <format> <field> <symmetry>
```

with `<format>` one of `coordinate` or `array`, `<field>` one of `real`,
`integer` or `pattern`, and `<symmetry>` one of `general`, `symmetric` or
`skew-symmetric`. Keywords are matched case-insensitively. `pattern` occurs
only with `coordinate`. Complex and Hermitian matrices never occur.

After the banner come zero or more comment lines, each starting with `%`;
comment lines appear only in this header block, never among the data. A line
that is empty or holds nothing but spaces and tabs is ignored everywhere in
the file. The first line that is neither blank nor a comment is the size
line; everything after it is data, one entry per line, tokens separated by
whitespace. `symmetric` and `skew-symmetric` files are square.

**coordinate.** The size line is `rows cols nnz`. The next `nnz` data lines
each hold `i j value` (1-based row, 1-based column, then the value), or just
`i j` when the field is `pattern`, in which case the value is `1.0`. Every
entry not listed is zero. Entries appear in no particular order and are never
repeated. For `symmetric` and `skew-symmetric` only entries with `i >= j` are
stored, and a stored entry `(i, j)` with `i != j` also sets `(j, i)` to the
same value, or to its negation for `skew-symmetric`; a `skew-symmetric` file
stores no diagonal entry.

**array.** The size line is `rows cols`, followed by the values in
column-major order (column 1 top to bottom, then column 2, and so on), one per
line. For `general` there are `rows*cols` of them. For `symmetric` only the
lower triangle is stored, `n(n+1)/2` values, again column-major
(`(1,1),(2,1),…,(n,1),(2,2),(3,2),…`), and each off-diagonal value also sets
the mirrored entry. For `skew-symmetric` only the strict lower triangle is
stored, `n(n-1)/2` values, and the mirrored entry is the negation.

Values are written in any form the language's usual decimal-float parser
accepts (`1`, `-2.5`, `3.0e-7`, `1.0E+03`). They parse to IEEE-754 binary64.
All input values are finite. Every input file parses exactly as written: the
test inputs print enough digits to round-trip, so two implementations that use
a correctly rounded decimal-to-binary conversion read bit-identical matrices.

An input matrix is held densely: the storage variants above are three ways of
writing the same `rows x cols` array of doubles, and nothing downstream
depends on which was used.

## 2. The output directory

Every command writes its results into the output directory. File names are
`NNN_<suffix>` where `NNN` is the command number as three digits with leading
zeros (`001`, `017`, `200`).

| command | result files |
|---|---|
| `add` | `NNN_add.mtx` |
| `mul` | `NNN_mul.mtx` |
| `transpose` | `NNN_transpose.mtx` |
| `lu` | `NNN_lu_P.mtx`, `NNN_lu_L.mtx`, `NNN_lu_U.mtx` |
| `det` | `NNN_det.mtx` (1x1) |
| `inv` | `NNN_inv.mtx` |
| `solve` | `NNN_solve.mtx` |
| `qr` | `NNN_qr_Q.mtx`, `NNN_qr_R.mtx` |
| `chol` | `NNN_chol_L.mtx` |
| `eig` | `NNN_eig_w.mtx` (n x 1), `NNN_eig_V.mtx` (n x n) |
| `svd` | `NNN_svd_U.mtx` (m x k), `NNN_svd_S.mtx` (k x 1), `NNN_svd_V.mtx` (n x k) |
| `lstsq` | `NNN_lstsq.mtx` |
| `norm1`, `norminf`, `normfro`, `cond` | `NNN_<op>.mtx` (1x1) |

A command that fails (section 5) writes `NNN_error.txt` instead and none of
the files above. Nothing else may appear in the output directory: no logs, no
subdirectories, no copies of the input.

### 2.1 Result file format

Every result matrix is written in Matrix Market **array real general** form,
whatever the input storage was:

```
%%MatrixMarket matrix array real general
<rows> <cols>
<value>
<value>
...
```

with `rows*cols` values in column-major order, one per line, and a trailing
newline at the end of the file. No comment lines.

Each value is formatted exactly as C's `printf("%.10e")` would: an optional
minus sign, one digit, a point, ten fractional digits, `e`, a sign, and at
least two exponent digits — `1.2345678901e+00`, `-7.0000000000e-03`,
`4.0015422479e+04`. Negative zero is written as `0.0000000000e+00`:
normalise `-0.0` to `0.0` before printing. No result is ever infinite or NaN
for the inputs used here.

The checker (section 6) enforces that shape token by token — ten fractional
digits, an `e`, a signed exponent, one value per line — but compares the
values numerically, so the exact rounding of the last printed digit does not
matter. `-0.0000000000e+00` would compare equal to zero, but writing it is
still wrong: print `0.0000000000e+00`.

## 3. Operations

Throughout, `A[i][j]` is the entry in row `i`, column `j`, both 0-based, and
all arithmetic is IEEE-754 binary64 with round-to-nearest.

### 3.1 Elementwise and products

`add` returns `A[i][j] + B[i][j]`.

`mul` returns `C[i][j] = Σₖ A[i][k] B[k][j]`, each dot product accumulated in
one running sum over increasing `k`.

`transpose` returns the `n x m` matrix `Aᵀ[j][i] = A[i][j]`.

### 3.2 Norms

- `norm1` — the maximum over columns of `Σᵢ |A[i][j]|`, each column summed
  over increasing `i`.
- `norminf` — the maximum over rows of `Σⱼ |A[i][j]|`, each row summed over
  increasing `j`.
- `normfro` — `sqrt(Σᵢⱼ A[i][j]²)`, the squares summed row by row, each row
  over increasing `j` and the rows over increasing `i`.

Each is written as a 1x1 matrix.

### 3.3 LU with partial pivoting

Factor the square matrix as `P A = L U` by right-looking Gaussian
elimination. Work on a copy `M` of `A` and on a row permutation, initially the
identity. For `k = 0 … n-1`:

1. Find `p`, the row index in `k … n-1` with the largest `|M[i][k]|`. If
   several rows attain that maximum, take the smallest such `i`.
2. If `|M[p][k]|` is exactly `0.0`, the matrix is singular (section 5).
3. If `p != k`, swap rows `k` and `p` of `M` and of the permutation.
4. For `i = k+1 … n-1`: set `f = M[i][k] / M[k][k]`, store `M[i][k] = f`, and
   for `j = k+1 … n-1` set `M[i][j] = M[i][j] - f * M[k][j]`.

Follow this order exactly. It fixes the rounding of every intermediate, and
with it the pivot chosen at every step.

The results are: `P`, the `n x n` permutation matrix with `P[i][perm[i]] = 1`
where `perm[i]` is the index in the original `A` of the row now sitting in row
`i`; `L`, unit lower triangular, `L[i][i] = 1`, `L[i][j] = M[i][j]` for
`j < i`, and exactly `0.0` above the diagonal; `U`, upper triangular,
`U[i][j] = M[i][j]` for `j >= i`, and exactly `0.0` below.

Because of the pivot rule every `|L[i][j]| <= 1`.

### 3.4 Determinant

Run the same elimination. If a pivot is exactly zero the determinant is
`0.0` — `det` never fails. Otherwise the determinant is the product of the
diagonal of `U`, taken in increasing index order, multiplied by `+1` if the
number of row swaps was even and `-1` if it was odd.

### 3.5 Inverse and solve

`solve A B` factors `A` and then, for each column of `B` independently:
permute it by `perm`, run forward substitution through `L` (whose diagonal is
1, so no division), then back substitution through `U` (dividing by `U[i][i]`
at each step). `inv A` is `solve A I` with `I` the `n x n` identity.

### 3.6 Householder QR

For `A` of shape `m x n` with `m >= n`, produce the thin factorisation
`A = Q R`, with `Q` of shape `m x n` having orthonormal columns and `R` of
shape `n x n` upper triangular.

Start with `R = A`. For `k = 0 … n-1`:

1. Let `x` be `R[k…m-1][k]` and `ν = sqrt(Σ x²)`. If `ν` is exactly `0.0`,
   the reflector is the identity; set `R[i][k] = 0` for `i > k` and continue.
2. Let `α = -ν` if `R[k][k] >= 0`, else `α = +ν`.
3. Let `v = x` with `v[0]` replaced by `v[0] - α`, then scale `v` to unit
   length.
4. For each column `j = k+1 … n-1`, subtract `2 (vᵀ R[k…m-1][j]) v` from
   `R[k…m-1][j]`.
5. Set `R[k][k] = α` and `R[i][k] = 0` for `i > k`.

Then form `Q` by starting from the first `n` columns of the `m x m` identity
and applying the stored reflectors in reverse order, `k = n-1 … 0`, each as
`Q[k…m-1][:] -= 2 v (vᵀ Q[k…m-1][:])`.

**Normalisation.** The factorisation is made unique by forcing a non-negative
diagonal on `R`: for each `j`, if `R[j][j] < 0`, negate row `j` of `R` and
column `j` of `Q`. Do this after the loop above, and write the strict lower
triangle of `R` as exact zeros.

### 3.7 Cholesky

For a symmetric positive definite `A`, produce the lower triangular `L` with
`A = L Lᵀ` and a strictly positive diagonal, computed column by column: for
`j = 0 … n-1`,

```
s = A[j][j] - Σ_{k<j} L[j][k]²          (accumulated over increasing k)
if s <= 0                               -> not_positive_definite
L[j][j] = sqrt(s)
for i = j+1 … n-1:
    L[i][j] = (A[i][j] - Σ_{k<j} L[i][k] L[j][k]) / L[j][j]
```

Entries above the diagonal are exactly `0.0`.

### 3.8 Symmetric eigendecomposition — cyclic Jacobi

For a symmetric `A`, produce eigenvalues `w` (an `n x 1` matrix, ascending)
and an orthogonal `V` whose column `j` is a unit eigenvector for `w[j]`, so
that `A V = V diag(w)`.

Work on a copy `M` of `A` and on `V`, initially the `n x n` identity. Let
`off(M) = sqrt(2 Σ_{i<j} M[i][j]²)`, the strict upper triangle summed in
row-major order, and `φ = ‖A‖F` as section 3.2 computes it. Carry one extra
number `prev`, set to `+∞` before the first sweep. At most 60 sweeps run, and
before each one:

```
off = off(M)
if off <= 1e-14 * φ or off >= prev:   the sweeps are finished
prev = off
run one sweep
```

So `prev` always holds the value `off(M)` had before the sweep that has just
finished, and because it starts at `+∞` the first sweep always runs. A sweep
visits the pairs `(p, q)` with `p < q` in row-major order — `(0,1), (0,2), …, (0,n-1),
(1,2), …` — and for each pair with `M[p][q] != 0.0`:

```
θ = (M[q][q] - M[p][p]) / (2 M[p][q])
t = 1 / (θ + sqrt(θ² + 1))      if θ >= 0
t = -1 / (-θ + sqrt(θ² + 1))    if θ < 0
c = 1 / sqrt(t² + 1)
s = t c
```

then apply the rotation as `M ← JᵀM J` in two passes — first update the
columns, `M[i][p], M[i][q] ← c M[i][p] - s M[i][q], s M[i][p] + c M[i][q]`
for every `i`, then the rows, `M[p][j], M[q][j] ← c M[p][j] - s M[q][j],
s M[p][j] + c M[q][j]` for every `j` — set `M[p][q]` and `M[q][p]` to exactly
`0.0`, and update `V[i][p], V[i][q] ← c V[i][p] - s V[i][q], s V[i][p] +
c V[i][q]` for every `i`.

The eigenvalues are the diagonal of `M` when the sweeps stop. Sort them
ascending, breaking ties by the smaller original index, and order the columns
of `V` to match. Then sign-normalise each column (section 3.11).

### 3.9 SVD — one-sided Jacobi

For `A` of shape `m x n`, with `k = min(m, n)`, produce `U` (`m x k`,
orthonormal columns), `s` (`k x 1`, descending, non-negative) and `V`
(`n x k`, orthonormal columns) with `A = U diag(s) Vᵀ`.

If `m < n`, run the algorithm below on `Aᵀ` and swap the roles of the two
factors at the end: the left vectors of `Aᵀ` are the right vectors of `A` and
vice versa. Sign normalisation is applied afterwards, to the final `U`.

Call the working matrix (`A` itself, or `Aᵀ` when `m < n`) `m' x n'`, so
`m' >= n'` and `n' = k`. Let `W` be a copy of it held as its `n'` columns,
and `V` the `n' x n'` identity. Repeat sweeps, at most 60, visiting the pairs
`(p, q)` with `0 <= p < q < n'` in the same row-major order. For each pair
compute

```
α = Σᵢ W[i][p]², β = Σᵢ W[i][q]², γ = Σᵢ W[i][p] W[i][q]
```

and skip the pair when `γ`, `α` or `β` is exactly `0.0`, or when
`|γ| <= 1e-14 * sqrt(α β)`. Otherwise rotate:

```
ζ = (β - α) / (2 γ)
t = 1 / (ζ + sqrt(ζ² + 1))      if ζ >= 0
t = -1 / (-ζ + sqrt(ζ² + 1))    if ζ < 0
c = 1 / sqrt(t² + 1)
s = t c
W[i][p], W[i][q] ← c W[i][p] - s W[i][q], s W[i][p] + c W[i][q]   for all i
V[i][p], V[i][q] ← c V[i][p] - s V[i][q], s V[i][p] + c V[i][q]   for all i
```

Stop when a whole sweep rotates nothing. The singular values are then the
column norms `σⱼ = ‖W[:][j]‖₂`, the left vectors are `W[:][j] / σⱼ` (the zero
vector when `σⱼ` is zero), and the right vectors are the columns of `V`.
Sort by `σ` descending, breaking ties by the smaller original index, and
reorder all three outputs together.

### 3.10 Least squares and condition number

`lstsq A B` returns the `n x k` minimiser of `‖A X - B‖F` for `A` of shape
`m x n` with `m >= n` and full column rank: factor `A = Q R` as in section
3.6 and solve `R X = Qᵀ B` by back substitution, one column of `B` at a time.
(`Qᵀ B` is formed from the normalised `Q`, so the sign convention cancels and
the answer is the ordinary least squares solution.)

`cond A` returns `σ_max / σ_min`, the largest and smallest of the `k`
singular values from section 3.9, as a 1x1 matrix.

### 3.11 Sign normalisation

Eigenvectors and singular vectors are only determined up to sign, so one is
fixed. For a column `v`, let `i*` be the **smallest** index attaining
`max_i |v[i]|`. If `v[i*] < 0`, negate the whole column; otherwise leave it.
A column that is entirely zero is left as it is.

- `eig`: apply this to each column of `V` independently.
- `svd`: apply it to each column of `U`, and negate the matching column of
  `V` whenever `U`'s column was negated, so that `A = U diag(s) Vᵀ` still
  holds. Never normalise `V` on its own.

The test inputs guarantee that the choice is unambiguous: in every
eigenvector and left singular vector produced, the largest magnitude exceeds
the second largest by at least a factor `1 + 1e-5`.

## 4. Guarantees about the test data

Floating point makes some results discontinuous in the input, so the test
matrices avoid the discontinuities. An implementation may rely on all of
this:

- **Pivots.** In every matrix a `lu` command names, the pivot candidates at
  each elimination step are either exactly equal — resolved by the
  smallest-index rule, which every implementation that follows section 3.3
  resolves the same way — or separated by more than a factor `1 + 1e-5`. No
  `lu` command is given a matrix whose pivot order hangs on rounding.
- **Spectra.** In every matrix an `eig` command names, consecutive
  eigenvalues differ by at least `1e-4` times the spread `w[n-1] - w[0]`. In
  every matrix an `svd` command names, consecutive singular values differ by
  at least `1e-4 * σ_max`. So the eigenvectors and singular vectors are
  well-determined.
- **Signs.** The margin in section 3.11 holds.
- **Rank.** No `svd` command is given a matrix with a zero singular value
  (the smallest over the whole suite is `1e-6` times the largest), so every
  left and right singular vector is a genuine unit vector and the sign rule
  of section 3.11 always has something to act on. `qr` and `lstsq` do see
  rank-deficient matrices; `qr` still succeeds there (section 3.6 step 1
  handles the zero column) while `lstsq` reports `singular`.
- **Conditioning.** Matrices given to `inv`, `solve`, `lstsq` and `cond` by a
  command that succeeds have a condition number below `1e8`; matrices given
  to `chol` by a command that succeeds are positive definite with a
  comfortable margin. Ill-conditioned matrices do appear, but only under
  `norm*`, `transpose`, `add`, `mul`, `det` and `lu`. The exception is the
  handful of exactly singular or indefinite matrices of section 5, which are
  there to be reported as errors rather than solved.
- **Range.** No result overflows: every value written is finite.

## 5. Errors

A command that cannot be carried out writes `NNN_error.txt` — one line, the
error code, and a newline — and no other file. The rest of the script runs
normally; the program still exits 0.

| code | raised when |
|---|---|
| `dimension_mismatch` | `add` with differing shapes; `mul` with `A`'s column count different from `B`'s row count; `solve` or `lstsq` whose right hand side has the wrong number of rows; `qr` or `lstsq` on a matrix with `m < n` |
| `not_square` | `lu`, `det`, `inv`, `chol`, `eig`, or the first argument of `solve`, given a non-square matrix |
| `not_symmetric` | `chol` or `eig` given a square matrix with `A[i][j] != A[j][i]` for some `i, j`, compared as exact doubles |
| `not_positive_definite` | `chol` reaching a pivot `s <= 0` in section 3.7 |
| `singular` | `lu`, `inv` or `solve` hitting a pivot of exactly `0.0`; `lstsq` whose `R` has a diagonal entry of exactly `0.0`; `cond` whose smallest singular value is exactly `0.0` |

Checks are applied in a fixed order: each argument's own shape first, then
the relation between the arguments, then symmetry, then whatever the
numerical work discovers. So `chol` on a 2x3 matrix is `not_square`, not
`dimension_mismatch`; `eig` on a non-symmetric 3x3 is `not_symmetric` rather
than an attempt to diagonalise it; and `inv` on a non-square matrix is
`not_square`, never `singular`.

Where a two-argument command could raise two different codes the order
decides which:

- `solve A B` checks that `A` is square (`not_square`) **before** it looks at
  `B`'s row count (`dimension_mismatch`). `solve` with a 2x3 `A` and a 3x1
  `B` is therefore `not_square`.
- `lstsq A B` checks `A`'s own shape, `m >= n`, before `B`'s row count; both
  give `dimension_mismatch`, so the order is not observable.
- `add` and `mul` have only the one relational check each.

Only these five codes occur. Malformed scripts, missing files and unparsable
matrices are not tested; behaviour for them is unconstrained.

## 6. How results are checked

`verify.py` compares each result file with the expected one entry by entry.
An entry `a` matches the expected entry `e` when

```
|a - e| <= 1e-8 * |e| + 1e-12 * max(1, max|E|)
```

where `max|E|` is the largest magnitude anywhere in that expected file. The
absolute term is scaled by the file's magnitude because `%.10e` carries only
eleven significant digits, so a fixed `1e-12` floor would sit below the
resolution of the printed format for a matrix with large entries.

The verifier also insists on the printed form of section 2.1 — the banner,
one value per line, and every value matching `-?[0-9]\.[0-9]{10}e[+-][0-9]{2,}`
— so a file with the right numbers in the wrong format is rejected.

On top of that, the verifier checks structure and residuals: `P` really is a
permutation matrix, `L` is unit lower triangular with entries at most 1 in
magnitude, `R` and `U` are upper triangular, `R`'s diagonal is non-negative,
eigenvalues ascend, singular values descend, vectors are sign-normalised,
and — for matrices up to 120 on a side — `P A = L U`, `Q ᵀQ = I`, `Q R = A`,
`L Lᵀ = A`, `A X = I`, `A X = B`, `A V = V diag(w)` and `U diag(s) Vᵀ = A`
each hold to a small residual. Getting the numbers right but the conventions
wrong fails.

A reference implementation following this document to the letter agrees with
LAPACK (through numpy) on every test to well within that tolerance — the
worst disagreement over the whole suite is about a fifth of what is allowed,
and on most tests it is under a hundredth.

## 7. Worked examples

### 7.1 A whole run

`input/commands.txt`:

```
# a two by two example
add a.mtx b.mtx

det a.mtx
chol s.mtx
```

`input/a.mtx` (array, general):

```
%%MatrixMarket matrix array real general
2 2
1.0
3.0
2.0
4.0
```

so `A = [[1, 2], [3, 4]]` — remember the values are column-major.

`input/b.mtx` (coordinate, general):

```
%%MatrixMarket matrix coordinate real general
2 2 2
1 1 0.5
2 2 -1.5
```

so `B = [[0.5, 0], [0, -1.5]]`.

`input/s.mtx` (array, symmetric — the lower triangle only):

```
%%MatrixMarket matrix array real symmetric
2 2
4.0
2.0
5.0
```

so `S = [[4, 2], [2, 5]]`.

The blank line and the `#` line are skipped, so `add` is command 1, `det` is
command 2 and `chol` is command 3. The output directory receives exactly
three files.

`001_add.mtx`:

```
%%MatrixMarket matrix array real general
2 2
1.5000000000e+00
3.0000000000e+00
2.0000000000e+00
2.5000000000e+00
```

`002_det.mtx` — elimination picks row 1 as the first pivot (`|3| > |1|`), one
swap, `U = [[3, 4], [0, 2/3]]`, so the determinant is `-(3 * 2/3) = -2`:

```
%%MatrixMarket matrix array real general
1 1
-2.0000000000e+00
```

`003_chol_L.mtx` — `L = [[2, 0], [1, 2]]`:

```
%%MatrixMarket matrix array real general
2 2
2.0000000000e+00
1.0000000000e+00
0.0000000000e+00
2.0000000000e+00
```

### 7.2 QR sign normalisation

For `A = [[3], [4]]` (one column), the reflector gives `R = [[-5]]` before
normalisation. Since `R[0][0] < 0`, negate row 0 of `R` and column 0 of `Q`:

```
001_qr_Q.mtx     ->  6.0000000000e-01
                     8.0000000000e-01
001_qr_R.mtx     ->  5.0000000000e+00
```

### 7.3 Eigenvector sign and order

For `A = [[2, 1], [1, 3]]` the eigenvalues are `(5 ± sqrt(5))/2`, i.e.
`1.3819660113` and `3.6180339887`, written ascending. The unnormalised
eigenvector for the first is proportional to `(-1.618, 1)`; its
largest-magnitude component is the first, which is negative, so the whole
column is negated to `(0.8506508084, -0.5257311121)`.

```
001_eig_w.mtx    ->  1.3819660113e+00
                     3.6180339887e+00
001_eig_V.mtx    ->  8.5065080835e-01     (column 0)
                    -5.2573111212e-01
                     5.2573111212e-01     (column 1)
                     8.5065080835e-01
```

### 7.4 An error

```
chol r.mtx
```

with `r.mtx` a 2x3 matrix writes `001_error.txt` containing

```
not_square
```

and no `001_chol_L.mtx`.

## 8. Shape of the work

A complete implementation is roughly 900 to 1500 lines in a systems language:

- a Matrix Market reader covering the six storage combinations of section
  1.2, and a writer for the fixed output form (about 150 lines);
- a dense matrix type over `double` with the elementwise operations,
  multiplication, transpose and the three norms (about 100 lines);
- the factorisations — LU with pivoting and its solve/inverse/determinant
  users, Householder QR and least squares, Cholesky, cyclic Jacobi for the
  symmetric eigenproblem, one-sided Jacobi for the SVD and the condition
  number (about 500 lines, the bulk of the work);
- the ordering and sign conventions of section 3.11, which are short but are
  what makes two implementations agree;
- the command dispatcher, the error taxonomy and the file naming (about 150
  lines).

The largest test matrix is 494x494 and the largest test script has 25
commands.
`tests/001_add_transpose` through `tests/022_near_singular` are small enough
to debug by hand; the later cases use matrices from the SuiteSparse Matrix
Collection, whose provenance is recorded in `corpus/LICENSE`.
