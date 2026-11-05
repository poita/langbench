package scheme

// Error categories reported by the interpreter.
const (
	ErrUnboundVariable = "unbound-variable"
	ErrType            = "type-error"
	ErrArity           = "arity-error"
	ErrDivisionByZero  = "division-by-zero"
	ErrUser            = "user-error"
	// ErrSyntax is reported for malformed programs (outside the language
	// specification, which only requires well-formed input).
	ErrSyntax = "syntax-error"
)

// Error is the error returned when evaluation fails. Category is one of the
// Err* constants.
type Error struct {
	Category string
}

// Error implements the error interface.
func (e *Error) Error() string { return "error: " + e.Category }

func throw(category string) {
	panic(&Error{Category: category})
}
