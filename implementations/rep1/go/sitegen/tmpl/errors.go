package tmpl

import "fmt"

// Kind classifies a template error.
type Kind int

// The kinds of error. They are the categories of the language definition.
const (
	KindSyntax    Kind = iota + 1 // unlexable or unparsable template
	KindFilter                    // unknown filter name in a loaded template
	KindUndefined                 // forbidden use of the undefined value
	KindTemplate                  // include or extends of a template that does not exist
	KindType                      // operand or argument of the wrong kind, division by zero, ...
)

func (k Kind) String() string {
	switch k {
	case KindSyntax:
		return "syntax"
	case KindFilter:
		return "filter"
	case KindUndefined:
		return "undefined"
	case KindTemplate:
		return "template"
	case KindType:
		return "type"
	}
	return "unknown"
}

// An Error is the error returned by loading and rendering templates.
type Error struct {
	Kind Kind
	Msg  string
}

func (e *Error) Error() string {
	if e.Msg == "" {
		return "template: " + e.Kind.String() + " error"
	}
	return fmt.Sprintf("template: %s error: %s", e.Kind, e.Msg)
}

// throw aborts the current load or render with an error. The panic is
// recovered at the API boundary and never escapes the package.
func throw(k Kind, format string, args ...any) {
	panic(&Error{Kind: k, Msg: fmt.Sprintf(format, args...)})
}
