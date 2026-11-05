package tmpl

import "fmt"

// ErrorKind classifies template errors.
type ErrorKind int

// The error kinds.
const (
	// SyntaxError: a template cannot be lexed or parsed.
	SyntaxError ErrorKind = iota + 1
	// FilterError: a loaded template uses an unknown filter.
	FilterError
	// UndefinedError: the undefined value was used.
	UndefinedError
	// TemplateError: include/extends names a template that does not exist.
	TemplateError
	// TypeError: an operand or argument has the wrong kind.
	TypeError
)

// String returns the short name of the kind: "syntax", "filter", "undefined",
// "template" or "type".
func (k ErrorKind) String() string {
	switch k {
	case SyntaxError:
		return "syntax"
	case FilterError:
		return "filter"
	case UndefinedError:
		return "undefined"
	case TemplateError:
		return "template"
	case TypeError:
		return "type"
	}
	return "unknown"
}

// Error is the error type returned by Engine.Render.
type Error struct {
	Kind ErrorKind
	Msg  string
}

func (e *Error) Error() string {
	return fmt.Sprintf("tmpl: %s error: %s", e.Kind, e.Msg)
}

func fail(kind ErrorKind, format string, args ...any) {
	panic(&Error{Kind: kind, Msg: fmt.Sprintf(format, args...)})
}
