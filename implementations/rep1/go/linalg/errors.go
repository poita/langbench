package linalg

import "errors"

// Sentinel errors returned by the library. Each error's text is a stable
// snake_case code, so err.Error() can be used directly as a machine-readable
// identifier. Use errors.Is to test for them.
var (
	// ErrDimensionMismatch: operand shapes are incompatible with the operation.
	ErrDimensionMismatch = errors.New("dimension_mismatch")
	// ErrNotSquare: a square matrix was required.
	ErrNotSquare = errors.New("not_square")
	// ErrNotSymmetric: a symmetric matrix was required (exact comparison).
	ErrNotSymmetric = errors.New("not_symmetric")
	// ErrNotPositiveDefinite: Cholesky met a non-positive pivot.
	ErrNotPositiveDefinite = errors.New("not_positive_definite")
	// ErrSingular: a pivot, diagonal entry or singular value was exactly zero.
	ErrSingular = errors.New("singular")
)
