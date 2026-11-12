/**
 * linalg — dense real linear algebra.
 *
 * Import `linalg` to get the whole public API:
 *
 * $(UL
 *   $(LI `linalg.matrix` — the dense `Matrix` type)
 *   $(LI `linalg.ops` — add, mul, transpose, norms)
 *   $(LI `linalg.lu` — LU, determinant, solve, inverse)
 *   $(LI `linalg.qr` — Householder QR and least squares)
 *   $(LI `linalg.cholesky` — Cholesky factorisation)
 *   $(LI `linalg.eigen` — symmetric eigenproblem, cyclic Jacobi)
 *   $(LI `linalg.svd` — one-sided Jacobi SVD and condition number)
 *   $(LI `linalg.mmio` — Matrix Market reading and writing)
 *   $(LI `linalg.script` — the command-script driver)
 * )
 */
module linalg;

public import linalg.cholesky;
public import linalg.eigen;
public import linalg.errors;
public import linalg.lu;
public import linalg.matrix;
public import linalg.mmio;
public import linalg.ops;
public import linalg.ordering;
public import linalg.qr;
public import linalg.script;
public import linalg.svd;
