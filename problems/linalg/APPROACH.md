# linalg — required approach

SPEC.md defines what the program does. This note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

Read `commands.txt` once, then run the commands in order. Each matrix file is
parsed the first time a command names it, from one bulk read of the file, into
a dense `rows x cols` array of doubles held in one flat contiguous buffer in
row-major order; the parsed matrix is cached by file name and every later
command reuses it. Each command computes its result from scratch with the
plain `O(n³)` algorithms SPEC.md prescribes (no blocking, no threads, no
sparse paths), with every inner loop arranged to walk memory contiguously.
Each result file is formatted into one buffer and written with one write.

Sizes below: a matrix is `m x n` (`n x n` when square), `k` is the number of
right-hand-side columns, `S` is the number of Jacobi sweeps (at most 60).

## Required choices

1. **Input.** Read each matrix file whole into memory and tokenize it in one
   pass over the bytes. Integers in the size line and in coordinate indices
   are parsed with a digit loop; values go through the language's standard
   correctly rounded decimal-to-double conversion, called on the token
   in place where the language allows it. Symmetric and skew-symmetric
   storage is expanded into the full dense array while reading.
2. **Parse once, cache by name.** A map from file name to parsed matrix;
   commands never modify a cached matrix (factorisations work on their own
   copy). Factorisation results are not cached across commands: `det`, `inv`
   and `solve` on the same file each factor it again.
3. **Representation.** One flat contiguous `double` array per matrix,
   row-major, with `rows` and `cols`. Inner loops take a view of the row (or
   column vector) they work on once, outside the loop, and index it directly.
   The Jacobi algorithms use the column-held working arrays of items 9 and 10.
   In an interpreted language where indexing a list of row lists is cheaper
   than indexing one flat array, a list of row lists (columns for the
   column-held arrays) is the equivalent representation. `norm1` keeps all
   column sums in one array and adds each row into it, so every column is
   still summed over increasing `i`.
4. **`mul`, O(m·k·n): row-axpy order.** For each row `i` of `A`, for each `k`
   in increasing order, add `A[i][k] * B[k][:]` into `C[i][:]`. Each `C[i][j]`
   still accumulates its products in one running sum over increasing `k`, so
   the result is identical to the dot-product form, but the inner loop runs
   along contiguous rows of `B` and `C` and has independent iterations.
5. **LU, O(n³).** Right-looking elimination on a row-major copy exactly as in
   SPEC.md 3.3; row swaps exchange whole rows (or row storage) and the update
   of row `i` is an axpy against row `k` over `j = k+1 … n-1`. `det` uses the
   same factorisation and stops at a zero pivot.
6. **`solve` and `inv`, O(n²·k) after the factorisation: all right-hand sides
   at once.** Hold `X` as a row-major `n x k` array initialised to the rows of
   `B` taken in `perm` order. Forward substitution: for `i = 1 … n-1`, for
   `j < i` increasing, `X[i][:] -= L[i][j] * X[j][:]`. Back substitution: for
   `i = n-1 … 0`, for `j > i` increasing, `X[i][:] -= U[i][j] * X[j][:]`, then
   divide row `i` by `U[i][i]`. Every entry sees the same operations in the
   same order as the per-column substitution of SPEC.md 3.5, but the inner loop
   is a contiguous row axpy. `inv` is this with `B = I` (`k = n`), O(n³).
7. **Householder QR, O(m·n²), row-oriented reflector application.** Keep `R`
   row-major. To apply reflector `k` to columns `j = k+1 … n-1`, first form
   `w[j] = Σ_{i=k}^{m-1} v[i] R[i][j]` by accumulating `v[i] * R[i][k+1:]` row
   by row over increasing `i` (per `j` this is the same sum in the same order),
   then update each row `R[i][k+1:] -= (2 w[:]) v[i]`. Store each unit
   reflector as its own vector. Form `Q` the same way, applying reflector `k`
   (in order `k = n-1 … 0`) only to columns `j = k … n-1`: columns `j < k` are
   still the unit vector `e_j`, have a zero dot product and are left exactly
   unchanged, so skipping them is bit-identical and halves the work. Then
   normalise signs. `lstsq` forms `Y = Qᵀ B` (O(m·n·k)) row-oriented too:
   for `i` increasing, for each `j`, `Y[j][:] += Q[i][j] * B[i][:]`, which is
   each dot product over increasing `i`; it then back-substitutes all `k`
   columns at once as in item 6.
8. **Cholesky, O(n³/3).** Row-major `L`, column by column as in SPEC.md 3.7;
   each sum runs over the leading parts of rows `i` and `j` of `L`, both
   contiguous, in a local variable that starts at `A[i][j]` (or `A[j][j]`)
   and has each product subtracted in increasing `k`.
9. **Symmetric eigensolver, O(S·n³).** Cyclic Jacobi with exactly SPEC.md
   3.8's pair order, skip rule, rotation formulas and stopping test. Store the
   eigenvector accumulator transposed: row `j` of an `n x n` array holds column
   `j` of `V`, so each rotation updates two contiguous rows. Apply the rotation
   to `M` using its exact symmetry (the input passed the symmetry check, and
   the two-pass update keeps `M` bitwise symmetric): with `a = M[p][p]`,
   `b = M[q][q]`, `g = M[p][q]` saved first, for every `j ∉ {p, q}` compute
   `x' = c·M[p][j] − s·M[q][j]`, `y' = s·M[p][j] + c·M[q][j]` once, store them in
   rows `p` and `q`, and copy rows `p` and `q` into columns `p` and `q`; then set
   the 2x2 block from the column-then-row passes,
   `P = c·a − s·g`, `Pq = s·a + c·g`, `Qp = c·g − s·b`, `Qq = s·g + c·b`,
   `M[p][p] = c·P − s·Qp`, `M[q][q] = s·Pq + c·Qq`, `M[p][q] = M[q][p] = 0.0`.
   This yields exactly the values of SPEC.md's two passes with one contiguous
   pass of arithmetic instead of a strided one. `off(M)` is computed once per
   sweep from the strict upper triangle.
10. **SVD, O(S·n'²·m').** One-sided Jacobi on `W` held as `n'` separate
    contiguous column vectors of length `m'` (built directly from `A`'s
    columns, or from `A`'s rows when `m < n`, with no separate transpose
    step), and `V` likewise held as `n'` contiguous columns. For each pair,
    `α`, `β` and `γ` are computed in a single fused pass over the two columns;
    a rotation updates the two columns of `W` and of `V`, all contiguous.
    The final `U`, `s` and `V` are assembled once after sorting.
11. **`cond` computes singular values only.** It runs the same sweeps on `W`
    without allocating or rotating `V` and without building `U`; the rotation
    decisions depend only on `W`, so the values are identical.
12. **Ordering and signs.** Sort an index array once (O(n log n)) with the
    tie-breaks of SPEC.md and permute columns once; sign normalisation is one
    O(n) scan per column.
13. **Output.** For each result file, format the banner, the size line and
    all `rows·cols` values in column-major order into one growing byte buffer
    (normalising `-0.0` first), using the standard library's `%.10e`-style
    formatting into a reused scratch buffer, then write the file with a
    single call. Error files are one short write.
14. **Floating-point semantics.** Strict IEEE double arithmetic in the order
    SPEC.md states. No compiler or library mode that reassociates or
    vectorises reductions by reordering sums (fast-math or equivalent); the
    speedups above come from loop order and layout, not from changing sums.
    Library summation routines that sum pairwise or with compensation are
    not the running sum SPEC.md states and are not used.

## Left to the implementer

- Container types, struct layout, naming, module structure, error
  propagation mechanism (exceptions, result values, error codes).
- Whether rows are addressed by offset into the flat buffer or through row
  views over it, and whether a row swap moves data or swaps row views.
- Skipping an axpy whose multiplier is exactly `0.0` (exact, and harmless).
- Whether the eigensolver's sweep loop and the SVD's sweep loop share code.
- How the `%.10e` text is produced (standard formatter, or a hand-written
  equivalent with the same output), and the size of read and write buffers.
- Whether multiply-add pairs are fused, where that is the compiler's or
  language's default behaviour rather than an opt-in fast-math mode.
- Loop-level micro-optimisations: bounds-check elimination, unrolling,
  pointer versus index style, integer width of indices, and compiler
  optimisation flags other than those excluded by item 14.

## Pitfalls

- Dot-product (`i-j-k`) matrix multiplication with the inner loop striding
  down a column of `B`: several times slower than the row-axpy order, which
  gives bit-identical results.
- One-sided Jacobi on a row-major `W` (or `V`), reading `W[i][p]` and
  `W[i][q]` with a stride of a full row; or computing `α`, `β`, `γ` in three
  separate strided passes. Hold the columns contiguously.
- Updating the eigenvector matrix `V[i][p], V[i][q]` down two columns of a
  row-major array; store it transposed. Likewise running SPEC.md's column pass
  over `M` literally with a stride of `n`.
- Substitution in `solve`/`inv`/`lstsq` that reads `X[j][c]` down a column of
  a row-major result inside the inner loop, or that accumulates into an array
  element rather than a local or a contiguous row.
- Building `U` and `V` (and rotating `V`) for `cond`, which needs only the
  singular values.
- Applying each Householder reflector to all `n` columns of `Q` when columns
  `j < k` are untouched.
- Re-reading and re-parsing a matrix file for every command that names it;
  or splitting the file into per-line strings and per-token heap strings.
- Formatting each value into a freshly allocated string, concatenating the
  output with repeated string appends that copy, or writing each value with
  a separate unbuffered write.
- Accessing elements through a generic accessor that recomputes offsets,
  checks bounds or dispatches dynamically inside the innermost loops, where
  the language offers a plain slice or row view instead.
- Representing a matrix as separately allocated row arrays or nested dynamic
  containers where the language offers one flat unboxed array.
