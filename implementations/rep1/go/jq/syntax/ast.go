// Package syntax implements the lexer and recursive-descent parser for the
// supported jq filter language and defines its abstract syntax tree.
package syntax

import "github.com/peter/jq/value"

// Op is the kind of an AST node.
type Op uint8

// Node kinds.
const (
	OpIdentity Op = iota // .
	OpLiteral            // Val
	OpVar                // $Name
	OpPipe               // A | B
	OpComma              // A , B
	OpNeg                // -A
	OpBinary             // A Bin B (arithmetic and comparison)
	OpAnd                // A and B
	OpOr                 // A or B
	OpArray              // [A] (A may be nil)
	OpObject             // {Entries}
	OpIf                 // if A then B else C (C may be nil: identity)
	OpReduce             // reduce A as $Name (B; C)
	OpAs                 // A as $Name | B
	OpCall               // Name(Args...)
	OpIndex              // A[B]; Optional makes the index operation tolerant
	OpIter               // A[]
	OpSlice              // A[B:C]; B or C may be nil
	OpTry                // (A)?
)

// BinOp is a binary arithmetic or comparison operator.
type BinOp uint8

// Binary operators.
const (
	Add BinOp = iota
	Sub
	Mul
	Div
	Mod
	Eq
	Ne
	Lt
	Le
	Gt
	Ge
)

// Node is a filter AST node. Which fields are meaningful depends on Op.
type Node struct {
	Op       Op
	A, B, C  *Node
	Name     string      // variable name or builtin name
	Val      value.Value // literal value
	Bin      BinOp
	Args     []*Node       // builtin call arguments
	Entries  []ObjectEntry // object construction
	Optional bool          // tolerant "?" on an index, iterate or slice
}

// ObjectEntry is one key/value pair of an object construction. Key is a
// literal string node or an arbitrary (computed) expression.
type ObjectEntry struct {
	Key, Value *Node
}
