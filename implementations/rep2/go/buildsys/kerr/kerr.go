// Package kerr defines the error type shared by every layer of the Kiln
// build system.
//
// A Kiln build fails with exactly one error. Each error has a Kind (such as
// "E_TYPE" or "E_CYCLE") and an optional Detail; the pair renders as the text
// that appears in the session log.
package kerr

import "fmt"

// Error is a Kiln build error.
type Error struct {
	// Kind is the error kind, for example "E_UNKNOWN_VAR".
	Kind string
	// Detail is the kind-specific detail text; it may be empty.
	Detail string
}

// Error renders the error as "KIND detail", or just "KIND" if there is no
// detail.
func (e *Error) Error() string {
	if e.Detail == "" {
		return e.Kind
	}
	return e.Kind + " " + e.Detail
}

// New returns an error of the given kind with a formatted detail.
func New(kind, format string, args ...any) *Error {
	if len(args) == 0 {
		return &Error{Kind: kind, Detail: format}
	}
	return &Error{Kind: kind, Detail: fmt.Sprintf(format, args...)}
}

// Kind constants for every error kind a build can raise.
const (
	Parse          = "E_PARSE"
	UnknownVar     = "E_UNKNOWN_VAR"
	Redefine       = "E_REDEFINE"
	SetUndefined   = "E_SET_UNDEFINED"
	Type           = "E_TYPE"
	Arity          = "E_ARITY"
	UnknownFunc    = "E_UNKNOWN_FUNC"
	UnknownRule    = "E_UNKNOWN_RULE"
	UnknownCmd     = "E_UNKNOWN_CMD"
	Arg            = "E_ARG"
	IncludeMissing = "E_INCLUDE_MISSING"
	IncludeCycle   = "E_INCLUDE_CYCLE"
	BadPath        = "E_BAD_PATH"
	OutputPath     = "E_OUTPUT_PATH"
	StepField      = "E_STEP_FIELD"
	CmdShape       = "E_CMD_SHAPE"
	DupOutput      = "E_DUP_OUTPUT"
	DupPhony       = "E_DUP_PHONY"
	MissingInput   = "E_MISSING_INPUT"
	UnknownTarget  = "E_UNKNOWN_TARGET"
	Cycle          = "E_CYCLE"
	NoDefault      = "E_NO_DEFAULT"
	RuleRecursion  = "E_RULE_RECURSION"
	DivZero        = "E_DIV_ZERO"
	Interp         = "E_INTERP"
	Abort          = "E_ABORT"
	NoBuildFile    = "E_NO_BUILD_FILE"
	NeedPath       = "E_NEED_PATH"
	NeedMissing    = "E_NEED_MISSING"
	NeedCycle      = "E_NEED_CYCLE"
)
