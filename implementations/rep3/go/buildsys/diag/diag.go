// Package diag defines the error type shared by every layer of Kiln.
//
// A Kiln build fails with exactly one error. Each error has a Kind (such as
// "E_CYCLE") and an optional Detail; the pair is rendered as the text of the
// `error` line in the session log.
package diag

import "fmt"

// Kind names a class of build error.
type Kind string

// The error kinds defined by the Kiln specification.
const (
	Parse          Kind = "E_PARSE"
	UnknownVar     Kind = "E_UNKNOWN_VAR"
	Redefine       Kind = "E_REDEFINE"
	SetUndefined   Kind = "E_SET_UNDEFINED"
	Type           Kind = "E_TYPE"
	Arity          Kind = "E_ARITY"
	UnknownFunc    Kind = "E_UNKNOWN_FUNC"
	UnknownRule    Kind = "E_UNKNOWN_RULE"
	UnknownCmd     Kind = "E_UNKNOWN_CMD"
	Arg            Kind = "E_ARG"
	IncludeMissing Kind = "E_INCLUDE_MISSING"
	IncludeCycle   Kind = "E_INCLUDE_CYCLE"
	BadPath        Kind = "E_BAD_PATH"
	OutputPath     Kind = "E_OUTPUT_PATH"
	StepField      Kind = "E_STEP_FIELD"
	CmdShape       Kind = "E_CMD_SHAPE"
	DupOutput      Kind = "E_DUP_OUTPUT"
	DupPhony       Kind = "E_DUP_PHONY"
	MissingInput   Kind = "E_MISSING_INPUT"
	UnknownTarget  Kind = "E_UNKNOWN_TARGET"
	Cycle          Kind = "E_CYCLE"
	NoDefault      Kind = "E_NO_DEFAULT"
	RuleRecursion  Kind = "E_RULE_RECURSION"
	DivZero        Kind = "E_DIV_ZERO"
	Interp         Kind = "E_INTERP"
	Abort          Kind = "E_ABORT"
	NoBuildFile    Kind = "E_NO_BUILD_FILE"
	NeedPath       Kind = "E_NEED_PATH"
	NeedMissing    Kind = "E_NEED_MISSING"
	NeedCycle      Kind = "E_NEED_CYCLE"
)

// Error is a Kiln build error.
type Error struct {
	Kind   Kind
	Detail string
}

// Error renders the error as "KIND detail" (or just "KIND" when there is no
// detail), which is exactly the text that follows `error ` in the log.
func (e *Error) Error() string {
	if e.Detail == "" {
		return string(e.Kind)
	}
	return string(e.Kind) + " " + e.Detail
}

// New builds an Error whose detail is formatted with fmt.Sprintf.
func New(kind Kind, format string, args ...any) *Error {
	if len(args) == 0 {
		return &Error{Kind: kind, Detail: format}
	}
	return &Error{Kind: kind, Detail: fmt.Sprintf(format, args...)}
}

// Bare builds an Error that has no detail.
func Bare(kind Kind) *Error { return &Error{Kind: kind} }
