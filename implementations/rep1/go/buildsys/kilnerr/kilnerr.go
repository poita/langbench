// Package kilnerr defines the error type shared by every stage of a Kiln
// build. A build either succeeds or fails with exactly one Error, which is
// rendered on a single line of the session log.
package kilnerr

// Error kinds. The set is exhaustive; see the specification's "Errors"
// section for the detail format of each.
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

// Error is a Kiln build error: a kind such as "E_TYPE" and an optional detail.
type Error struct {
	Kind   string
	Detail string
}

// New returns an Error with the given kind and detail.
func New(kind, detail string) *Error { return &Error{Kind: kind, Detail: detail} }

// Error renders the error as "KIND detail", or just "KIND" when there is no
// detail. This is exactly the text that follows "  error " in the log.
func (e *Error) Error() string {
	if e.Detail == "" {
		return e.Kind
	}
	return e.Kind + " " + e.Detail
}
