// Package kerr defines the error values reported by the Kiln build system.
//
// Every failed build ends with exactly one *Error, which has a Kind (one of
// the thirty E_* identifiers) and an optional Detail string. The rendered
// form, "KIND detail", is what appears on the "error" line of the session log.
package kerr

import "fmt"

// Kind identifies the category of a build error.
type Kind string

// The complete set of error kinds.
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

// Error renders the error as "KIND detail", or just "KIND" when there is no
// detail.
func (e *Error) Error() string {
	if e.Detail == "" {
		return string(e.Kind)
	}
	return string(e.Kind) + " " + e.Detail
}

// New builds an error of the given kind with a formatted detail.
func New(kind Kind, format string, args ...any) *Error {
	if len(args) == 0 {
		return &Error{Kind: kind, Detail: format}
	}
	return &Error{Kind: kind, Detail: fmt.Sprintf(format, args...)}
}

// NewParse builds an E_PARSE error for the given build file and line.
func NewParse(file string, line int) *Error {
	return &Error{Kind: Parse, Detail: fmt.Sprintf("%s:%d", file, line)}
}

// NewType builds an E_TYPE error: "<site>: expected <want>, got <got>".
func NewType(site, want, got string) *Error {
	return &Error{Kind: Type, Detail: site + ": expected " + want + ", got " + got}
}
