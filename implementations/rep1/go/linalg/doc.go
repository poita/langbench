// Package linalg is a small dense real linear algebra library written from
// scratch on top of the Go standard library only.
//
// It provides a row-major [Matrix] type, elementwise operations, products and
// norms (matrix.go), LU factorisation with partial pivoting together with
// determinant, solve and inverse (lu.go), Householder QR and least squares
// (qr.go), Cholesky (chol.go), the cyclic Jacobi symmetric eigensolver
// (eig.go) and the one-sided Jacobi SVD with the condition number (svd.go).
//
// The algorithms are the classical O(n³) ones. Every sum is a single running
// sum in a fixed, documented order, and products are wrapped in explicit
// float64 conversions so the compiler never fuses a multiply and an add into
// an FMA: results are bit-for-bit reproducible across platforms.
//
// Failures that depend on the data (shape mismatches, singular matrices, ...)
// are reported as the sentinel errors declared in errors.go; use [errors.Is]
// to test for them or [ErrorCode] to obtain their stable string name.
package linalg
