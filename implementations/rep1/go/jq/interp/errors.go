package interp

import (
	"fmt"

	"github.com/peter/jq/value"
)

// Error is a runtime error raised by evaluation, either by a failing
// operation or explicitly by the error builtin.
type Error struct {
	// Value is the error payload: the message string for failing operations,
	// or the argument of error(f).
	Value value.Value
}

func (e *Error) Error() string {
	if e.Value.Kind() == value.KindString {
		return e.Value.Str()
	}
	return value.JSON(e.Value) + " (not a string)"
}

func errorf(format string, args ...any) error {
	return &Error{Value: value.String(fmt.Sprintf(format, args...))}
}

// describe renders a value for use inside an error message.
func describe(v value.Value) string {
	s := value.JSON(v)
	if len(s) > 11 {
		s = s[:10] + "..."
	}
	return fmt.Sprintf("%s (%s)", v.TypeName(), s)
}
