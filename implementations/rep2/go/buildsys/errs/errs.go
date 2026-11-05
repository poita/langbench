// Package errs defines the error type shared by every Kiln package.
//
// A build fails with exactly one Error, which is rendered into the session
// log as "error <Kind> <Detail>".
package errs

import "fmt"

// Kind names a class of build error (for example "E_PARSE").
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

// Error is a Kiln build error: a kind plus an optional detail string.
type Error struct {
	Kind   Kind
	Detail string
}

// New returns an error of the given kind with a formatted detail.
func New(kind Kind, format string, args ...any) *Error {
	if len(args) == 0 {
		return &Error{Kind: kind, Detail: format}
	}
	return &Error{Kind: kind, Detail: fmt.Sprintf(format, args...)}
}

// Bare returns an error of the given kind that has no detail.
func Bare(kind Kind) *Error { return &Error{Kind: kind} }

// Error renders the error as "<KIND> <detail>", or just "<KIND>" when there
// is no detail. This is exactly the text that follows "  error " in a log.
func (e *Error) Error() string {
	if e.Detail == "" {
		return string(e.Kind)
	}
	return string(e.Kind) + " " + e.Detail
}
