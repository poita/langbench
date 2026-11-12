# linalg: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: a matrix is `m x n` (`n x n` when square, at most 494 on a side), `k` is
the number of right-hand-side columns, `S` the number of Jacobi sweeps (at most
60).

## Algorithm

The commands run in order. Each matrix file is parsed once, the first time a
command names it, into a dense `m x n` matrix of doubles (symmetric and
skew-symmetric storage expanded), kept in a map from file name to matrix. Each
command computes its result from scratch with the dense algorithms of SPEC.md
§3: the classical triple product for `mul`; LU by Gaussian elimination with
partial pivoting for `lu`, `det`, `solve` and `inv`, then forward and back
substitution; Householder QR for `qr` and `lstsq`; Cholesky for `chol`;
cyclic Jacobi for `eig`; one-sided Jacobi for `svd` and `cond`.

## Required rules

1. **Classical dense algorithms only.** No Strassen or other subcubic method,
   no blocked or parallel variants, and no special paths for sparse or
   structured inputs.
2. **Sums in SPEC.md's order.** Every sum is one running sum in the order
   SPEC.md gives. No pairwise or compensated summation and no reassociation.
3. **No factorisation is reused across commands**, so `det`, `inv` and
   `solve` on one file each factor it again.

## Complexity

Parsing is linear in the file size. `add`, `transpose` and the norms are
O(m·n); `mul` is O(m·n·k). LU, `det`, `inv` and `chol` are O(n³), `solve` is
O(n³ + n²·k), QR is O(m·n²) and `lstsq` adds O(m·n·k + n²·k). `eig` is O(S·n³)
and `svd`/`cond` O(S·n'²·m'), with `m' ≥ n'` the dimensions after the
transpose. Output is O(m·n) per result.
