package linalg

import "errors"

// Sentinel errors returned by the library. Their messages are stable
// machine-readable codes.
var (
	// ErrDimensionMismatch is returned when operand shapes are incompatible.
	ErrDimensionMismatch = errors.New("dimension_mismatch")
	// ErrNotSquare is returned when a square matrix is required.
	ErrNotSquare = errors.New("not_square")
	// ErrNotSymmetric is returned when a matrix is not exactly symmetric.
	ErrNotSymmetric = errors.New("not_symmetric")
	// ErrNotPositiveDefinite is returned by [Cholesky] on a non-positive pivot.
	ErrNotPositiveDefinite = errors.New("not_positive_definite")
	// ErrSingular is returned when an exactly zero pivot or singular value is met.
	ErrSingular = errors.New("singular")
)

var allErrors = []error{
	ErrDimensionMismatch, ErrNotSquare, ErrNotSymmetric,
	ErrNotPositiveDefinite, ErrSingular,
}

// ErrorCode returns the stable code ("singular", "not_square", ...) of err if
// it is, or wraps, one of the library's sentinel errors.
func ErrorCode(err error) (string, bool) {
	for _, e := range allErrors {
		if errors.Is(err, e) {
			return e.Error(), true
		}
	}
	return "", false
}
