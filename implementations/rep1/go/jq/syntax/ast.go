// Package syntax parses jq filter text into an abstract syntax tree.
//
// The accepted language is the jq subset described in the repository README:
// paths, slices, optional (?), pipes, commas, arithmetic and comparison,
// and/or, if/elif/else, variable binding with "as", reduce, array and object
// construction, and calls of builtin functions.
package syntax

import "example.com/jq/value"

// Node is a filter expression. The concrete types are the pointer types
// declared in this file.
type Node interface{ isNode() }

type (
	// Identity is ".".
	Identity struct{}
	// Literal is a constant number, string, boolean or null.
	Literal struct{ Value value.Value }
	// Var is a variable reference such as $x.
	Var struct {
		Name string
		Pos  int
	}
	// Index is Term[Key] (also .name and ."name"). Opt marks a trailing "?"
	// that makes just this operation tolerant of errors.
	Index struct {
		Term, Key Node
		Opt       bool
	}
	// Iterate is Term[].
	Iterate struct {
		Term Node
		Opt  bool
	}
	// Slice is Term[From:To]; From or To may be nil.
	Slice struct {
		Term, From, To Node
		Opt            bool
	}
	// Try is Body? applied to a term that is not a path operation: errors
	// raised inside Body end its output stream silently.
	Try struct{ Body Node }
	// Pipe is L | R.
	Pipe struct{ L, R Node }
	// Comma is L , R.
	Comma struct{ L, R Node }
	// Binary is an arithmetic or comparison operator; Op is one of
	// + - * / % == != < <= > >=.
	Binary struct {
		Op   string
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
	Object struct{ Entries []Entry }
	// If is if Cond then Then else Else end; Else is nil when omitted
	// (meaning identity).
	If struct{ Cond, Then, Else Node }
	// As is Src as $Name | Body.
	As struct {
		Src  Node
		Name string
		Body Node
	}
	// Reduce is reduce Src as $Name (Init; Update).
	Reduce struct {
		Src          Node
		Name         string
		Init, Update Node
	}
	// Call is a builtin function call.
	Call struct {
		Name string
		Args []Node
		Pos  int
	}
)

// Entry is one key/value pair of an object construction.
type Entry struct{ Key, Val Node }

func (*Identity) isNode() {}
func (*Literal) isNode()  {}
func (*Var) isNode()      {}
func (*Index) isNode()    {}
func (*Iterate) isNode()  {}
func (*Slice) isNode()    {}
func (*Try) isNode()      {}
func (*Pipe) isNode()     {}
func (*Comma) isNode()    {}
func (*Binary) isNode()   {}
func (*And) isNode()      {}
func (*Or) isNode()       {}
func (*Neg) isNode()      {}
func (*Array) isNode()    {}
func (*Object) isNode()   {}
func (*If) isNode()       {}
func (*As) isNode()       {}
func (*Reduce) isNode()   {}
func (*Call) isNode()     {}
