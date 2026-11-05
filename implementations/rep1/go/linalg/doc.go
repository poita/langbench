// Package linalg is a small dense real linear algebra library written from
// scratch on top of the Go standard library (no BLAS/LAPACK-style routines
// are used).
//
// Matrices are held in the flat row-major Matrix type. The package provides
//
//   - elementwise and product operations: Add, Mul, Transpose;
//   - norms: Norm1, NormInf, NormFro;
//   - LU factorisation with partial pivoting (NewLU), Det, Solve, Inverse;
//   - Householder QR (QR) and least squares (LeastSquares);
//   - Cholesky factorisation (Cholesky);
//   - the symmetric eigenproblem by cyclic Jacobi (EigSym);
//   - the SVD by one-sided Jacobi (SVD, SingularValues, Cond).
//
// All floating-point work follows a fixed operation order (documented on each
// function), so results are reproducible and match the reference algorithms
// digit for digit up to platform fused-multiply-add behaviour.
//
// Failures are reported as one of the sentinel errors (ErrDimensionMismatch,
// ErrNotSquare, ErrNotSymmetric, ErrNotPositiveDefinite, ErrSingular), whose
// Error text is the stable machine-readable code. Matrix Market input and
// output live in the sub-package linalg/mmio.
package linalg
