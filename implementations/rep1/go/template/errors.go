package template

import "fmt"

// ErrorKind classifies a template failure. The string form of a kind is the
// word printed after "error: " by the command-line tool.
type ErrorKind string

// The five error kinds.
const (
	// ErrSyntax is an unlexable or unparsable template.
	ErrSyntax ErrorKind = "syntax"
	// ErrFilter is a reference to an unknown filter in a loaded template.
	ErrFilter ErrorKind = "filter"
	// ErrUndefined is a forbidden use of the undefined value.
	ErrUndefined ErrorKind = "undefined"
	// ErrTemplate is an include or extends of a template that does not exist.
	ErrTemplate ErrorKind = "template"
	// ErrType is an operand or argument of the wrong kind, a division by
	// zero, a wrong argument count and similar failures.
	ErrType ErrorKind = "type"
)

// Error is the error type returned by the library for every template
// failure. Use errors.As to retrieve it and inspect Kind.
type Error struct {
	Kind ErrorKind
	Msg  string
}

// Error implements the error interface.
func (e *Error) Error() string {
	if e.Msg == "" {
		return "template: " + string(e.Kind) + " error"
	}
	return "template: " + string(e.Kind) + " error: " + e.Msg
}

// throw aborts the current load or render by panicking with an *Error. The
// panic is recovered at the public API boundary.
func throw(kind ErrorKind, format string, args ...any) {
	panic(&Error{Kind: kind, Msg: fmt.Sprintf(format, args...)})
}
