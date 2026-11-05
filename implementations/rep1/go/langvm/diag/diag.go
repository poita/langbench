// Package diag defines the single compile-time diagnostic that the Vellum
// toolchain reports: a kind (one of the 51 kinds of SPEC section 13.4) and a
// source position.
package diag

import "fmt"

// Pos is a 1-based line and column. Columns count Unicode scalar values.
type Pos struct {
	Line, Col int
}

// Kind names a class of compile error, spelled exactly as printed.
type Kind string

// The diagnostic kinds.
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

// Error is a compile error. It implements error; its text is the exact
// diagnostic line (without the trailing newline).
type Error struct {
	Kind Kind
	Pos  Pos
}

// Error returns "error: <kind> at <line>:<col>".
func (e *Error) Error() string {
	return fmt.Sprintf("error: %s at %d:%d", e.Kind, e.Pos.Line, e.Pos.Col)
}

// New builds an *Error.
func New(k Kind, p Pos) *Error { return &Error{Kind: k, Pos: p} }
