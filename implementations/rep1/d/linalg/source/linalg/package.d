/**
 * linalg — dense real linear algebra in plain D.
 *
 * Import `linalg` to get everything:
 * $(UL
 *   $(LI `linalg.matrix` — the `Matrix` type, add/multiply/transpose, norms)
 *   $(LI `linalg.lu` — LU with partial pivoting, determinant, solve, inverse)
 *   $(LI `linalg.qr` — Householder QR and least squares)
 *   $(LI `linalg.cholesky` — Cholesky factorisation)
 *   $(LI `linalg.eigen` — symmetric eigendecomposition (cyclic Jacobi))
 *   $(LI `linalg.svd` — SVD (one-sided Jacobi) and condition number)
 *   $(LI `linalg.mmio` — Matrix Market reader and writer)
 *   $(LI `linalg.script` — the command-script driver used by the CLI)
 *   $(LI `linalg.errors` — `LinalgException` and `ErrorCode`)
 * )
 */
module linalg;

public import linalg.errors;
public import linalg.matrix;
public import linalg.lu;
public import linalg.qr;
public import linalg.cholesky;
public import linalg.eigen;
public import linalg.svd;
public import linalg.signs;
public import linalg.mmio;
public import linalg.script;
