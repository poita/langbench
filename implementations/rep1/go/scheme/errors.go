package scheme

import "fmt"

// ErrorKind is the category of a runtime error, exactly as printed after
// "error: " by the command-line tool.
type ErrorKind string

// The runtime error categories.
const (
	ErrUnboundVariable ErrorKind = "unbound-variable"
	ErrType            ErrorKind = "type-error"
	ErrArity           ErrorKind = "arity-error"
	ErrDivisionByZero  ErrorKind = "division-by-zero"
	ErrUser            ErrorKind = "user-error"
)

// Error is a Scheme runtime error.
type Error struct{ Kind ErrorKind }

func (e *Error) Error() string { return "error: " + string(e.Kind) }

// SyntaxError reports malformed program text or a malformed special form.
type SyntaxError struct {
	Msg string
	Pos int // byte offset in the source, or -1 if unknown
}

func (e *SyntaxError) Error() string {
	if e.Pos >= 0 {
		return fmt.Sprintf("syntax error at offset %d: %s", e.Pos, e.Msg)
	}
	return "syntax error: " + e.Msg
}

// Raise aborts evaluation with a runtime error of the given kind. It is meant
// to be called from Primitive implementations.
func Raise(kind ErrorKind) {
	panic(&Error{Kind: kind})
}

func syntaxError(msg string) {
	panic(&SyntaxError{Msg: msg, Pos: -1})
}
