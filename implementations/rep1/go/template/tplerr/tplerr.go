// Package tplerr defines the error type shared by every package of the
// template engine.
//
// Every failure the engine can report is classified by a [Kind]; the command
// line tool prints the kind and nothing else.
package tplerr

import (
	"errors"
	"fmt"
)

// Kind classifies a template failure.
type Kind string

// The kinds of failure.
const (
	// Syntax is an unlexable or unparsable template.
	Syntax Kind = "syntax"
	// Filter is an unknown filter name in a loaded template.
	Filter Kind = "filter"
	// Undefined is a forbidden use of the undefined value.
	Undefined Kind = "undefined"
	// Template is an include or extends naming a template that does not exist.
	Template Kind = "template"
	// Type is an operand or argument of the wrong kind.
	Type Kind = "type"
)

// Error is a template failure: a Kind plus a human-readable message.
type Error struct {
	Kind Kind
	Msg  string
}

// Error implements the error interface.
func (e *Error) Error() string {
	return fmt.Sprintf("template: %s error: %s", e.Kind, e.Msg)
}

// New returns an *Error of the given kind with a formatted message.
func New(kind Kind, format string, args ...any) error {
	return &Error{Kind: kind, Msg: fmt.Sprintf(format, args...)}
}

// KindOf reports the Kind of err if it is (or wraps) an *Error.
func KindOf(err error) (Kind, bool) {
	var e *Error
	if errors.As(err, &e) {
		return e.Kind, true
	}
	return "", false
}
