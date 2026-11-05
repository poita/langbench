// Package syntax contains the lexer, parser and abstract syntax tree for the
// supported jq filter language.
package syntax

import "example.com/jq/value"

// Node is a node of the filter syntax tree. The concrete types below are the
// only implementations.
type Node interface{ node() }

type (
	// Identity is ".".
	Identity struct{}

	// Literal is a constant: number, string, true, false or null.
	Literal struct{ Val value.Value }

	// Var is a variable reference such as $x.
	Var struct{ Name string }

	// Index is Term[Key] (also .foo and ."foo", where Key is a string
	// Literal). With Opt set, an indexing error skips the combination.
	Index struct {
		Term, Key Node
		Opt       bool
	}

	// Slice is Term[From:To]; From and To may be nil.
	Slice struct {
		Term, From, To Node
		Opt            bool
	}

	// Iterate is Term[].
	Iterate struct {
		Term Node
		Opt  bool
	}

	// Try is Term? applied to a term that is not a path suffix: errors
	// raised inside Term end its output stream silently.
	Try struct{ Term Node }

	// Pipe is L | R.
	Pipe struct{ L, R Node }

	// Comma is L , R.
	Comma struct{ L, R Node }

	// Binary is an arithmetic or comparison operator applied to L and R.
	Binary struct {
		Op   Op
		L, R Node
	}

	// And is L and R.
	And struct{ L, R Node }

	// Or is L or R.
	Or struct{ L, R Node }

	// Neg is unary minus.
	Neg struct{ X Node }

	// Array is [Body]; Body is nil for [].
	Array struct{ Body Node }

	// Object is an object construction.
	Object struct {
		Entries []ObjEntry
		// DistinctLiteralKeys is true when every key is a literal string
		// and no key repeats, so slots can be copied straight into the
		// resulting object.
		DistinctLiteralKeys bool
	}

	// If is a conditional; Else is nil when omitted (meaning ".").
	If struct{ Cond, Then, Else Node }

	// As is "Source as $Name | Body".
	As struct {
		Source Node
		Name   string
		Body   Node
	}

	// Reduce is "reduce Source as $Name (Init; Update)".
	Reduce struct {
		Source       Node
		Name         string
		Init, Update Node
	}

	// Call is a builtin call such as length or select(f).
	Call struct {
		Name string
		Args []Node
	}
)

// ObjEntry is one key: value pair of an object construction.
type ObjEntry struct{ Key, Val Node }

// Op is a binary operator.
type Op uint8

// Binary operators.
const (
	OpAdd Op = iota
	OpSub
	OpMul
	OpDiv
	OpMod
	OpEq
	OpNe
	OpLt
	OpLe
	OpGt
	OpGe
)

func (*Identity) node() {}
func (*Literal) node()  {}
func (*Var) node()      {}
func (*Index) node()    {}
func (*Slice) node()    {}
func (*Iterate) node()  {}
func (*Try) node()      {}
func (*Pipe) node()     {}
func (*Comma) node()    {}
func (*Binary) node()   {}
func (*And) node()      {}
func (*Or) node()       {}
func (*Neg) node()      {}
func (*Array) node()    {}
func (*Object) node()   {}
func (*If) node()       {}
func (*As) node()       {}
func (*Reduce) node()   {}
func (*Call) node()     {}
