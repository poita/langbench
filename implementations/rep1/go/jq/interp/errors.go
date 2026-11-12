package interp

import (
	"fmt"

	"example.com/jq/value"
)

// Error is a jq runtime error, as raised by a type mismatch or by the error
// builtin. Value is the error value (a message string for built-in failures).
type Error struct {
	Value value.Value
}

func (e *Error) Error() string {
	if s, ok := e.Value.(string); ok {
		return "jq: error: " + s
	}
	return "jq: error (not a string): " + value.String(e.Value)
}

func errf(format string, a ...any) error {
	return &Error{Value: fmt.Sprintf(format, a...)}
}

// describe renders a value for an error message: its type and a truncated
// JSON text.
func describe(v value.Value) string {
	s := value.String(v)
	if len(s) > 11 {
		s = s[:10] + "..."
	}
	return value.TypeName(v) + " (" + s + ")"
}

// passThrough wraps an error returned by a downstream consumer while it
// travels back through a try, so that the try does not swallow it.
type passThrough struct{ err error }

func (p *passThrough) Error() string { return p.err.Error() }
