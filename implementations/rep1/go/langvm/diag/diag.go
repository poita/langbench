// Package diag defines the single diagnostic a rejected Vellum program
// produces, and the source positions it carries.
package diag

import "fmt"

// Kind names a class of compile-time error. The spelling of each constant is
// the text printed in the diagnostic line.
type Kind string

// The fifty-one diagnostic kinds of SPEC.md section 13.4.
const (
	BadModule        Kind = "bad-module"
	DupModule        Kind = "dup-module"
	BadToken         Kind = "bad-token"
	IntRange         Kind = "int-range"
	BadEscape        Kind = "bad-escape"
	Unterminated     Kind = "unterminated"
	Parse            Kind = "parse"
	ReservedName     Kind = "reserved-name"
	DupName          Kind = "dup-name"
	UnknownModule    Kind = "unknown-module"
	UnknownType      Kind = "unknown-type"
	UnknownTrait     Kind = "unknown-trait"
	NotPublic        Kind = "not-public"
	ArityType        Kind = "arity-type"
	BadArity         Kind = "bad-arity"
	BadKeyType       Kind = "bad-key-type"
	SelfOutside      Kind = "self-outside"
	BuiltinTraitImpl Kind = "builtin-trait-impl"
	BadImplHead      Kind = "bad-impl-head"
	UnusedParam      Kind = "unused-param"
	DupImpl          Kind = "dup-impl"
	MissingMethod    Kind = "missing-method"
	ExtraMethod      Kind = "extra-method"
	SigMismatch      Kind = "sig-mismatch"
	NoMain           Kind = "no-main"
	UnknownName      Kind = "unknown-name"
	TypeMismatch     Kind = "type-mismatch"
	Arity            Kind = "arity"
	NotCallable      Kind = "not-callable"
	NotStruct        Kind = "not-struct"
	UnknownField     Kind = "unknown-field"
	MissingField     Kind = "missing-field"
	DupField         Kind = "dup-field"
	NotIndexable     Kind = "not-indexable"
	NotIterable      Kind = "not-iterable"
	NoMethod         Kind = "no-method"
	AmbigMethod      Kind = "ambig-method"
	UnsatisfiedBound Kind = "unsatisfied-bound"
	NotEq            Kind = "not-eq"
	NotOrd           Kind = "not-ord"
	CannotInfer      Kind = "cannot-infer"
	NonExhaustive    Kind = "non-exhaustive"
	Unreachable      Kind = "unreachable"
	MissingReturn    Kind = "missing-return"
	BadValueRef      Kind = "bad-value-ref"
	BadPattern       Kind = "bad-pattern"
	RefutablePattern Kind = "refutable-pattern"
	BreakOutside     Kind = "break-outside"
	AssignImmutable  Kind = "assign-immutable"
	AssignCaptured   Kind = "assign-captured"
	BadTarget        Kind = "bad-target"
)

// Pos is a 1-based line and column. Columns count Unicode scalar values.
type Pos struct {
	Line, Col int
}

// Error is a compile-time diagnostic: a kind and the position it is reported
// at. It implements the error interface; its text is exactly the line the
// command-line tool prints.
type Error struct {
	Kind Kind
	Pos  Pos
}

// New returns a diagnostic of the given kind at pos.
func New(kind Kind, pos Pos) *Error { return &Error{Kind: kind, Pos: pos} }

// Error renders the diagnostic as "error: <kind> at <line>:<col>".
func (e *Error) Error() string {
	return fmt.Sprintf("error: %s at %d:%d", e.Kind, e.Pos.Line, e.Pos.Col)
}
