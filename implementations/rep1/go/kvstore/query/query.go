// Package query defines the predicate tree of the Tessera query language and
// evaluates it against documents.
package query

import "example.com/kvstore/value"

// Op is a comparison operator.
type Op uint8

// Comparison operators.
const (
	Eq Op = iota
	Ne
	Lt
	Le
	Gt
	Ge
)

// String returns the operator's source spelling.
func (o Op) String() string {
	return [...]string{"==", "!=", "<", "<=", ">", ">="}[o]
}

// Node is a predicate tree node: And, Or, Not, Exists, Missing or Cmp.
type Node interface{ node() }

// And is true when both operands are.
type And struct{ L, R Node }

// Or is true when either operand is.
type Or struct{ L, R Node }

// Not negates its operand.
type Not struct{ X Node }

// Exists is true when Path resolves to a value.
type Exists struct{ Path value.Path }

// Missing is true when Path does not resolve to a value.
type Missing struct{ Path value.Path }

// Cmp compares the value at Path with Val.
type Cmp struct {
	Path value.Path
	Op   Op
	Val  value.Value
}

func (And) node()     {}
func (Or) node()      {}
func (Not) node()     {}
func (Exists) node()  {}
func (Missing) node() {}
func (Cmp) node()     {}

// Leaves flattens n over And nodes, left to right, returning the leaf nodes.
func Leaves(n Node) []Node {
	var out []Node
	var walk func(Node)
	walk = func(n Node) {
		if a, ok := n.(And); ok {
			walk(a.L)
			walk(a.R)
			return
		}
		out = append(out, n)
	}
	walk(n)
	return out
}

// Eval reports whether doc satisfies n.
func Eval(n Node, doc value.Value) bool {
	switch n := n.(type) {
	case And:
		return Eval(n.L, doc) && Eval(n.R, doc)
	case Or:
		return Eval(n.L, doc) || Eval(n.R, doc)
	case Not:
		return !Eval(n.X, doc)
	case Exists:
		_, ok := doc.Lookup(n.Path)
		return ok
	case Missing:
		_, ok := doc.Lookup(n.Path)
		return !ok
	case Cmp:
		x, ok := doc.Lookup(n.Path)
		if !ok {
			return false
		}
		return compare(x, n.Op, n.Val)
	}
	return false
}

func compare(x value.Value, op Op, v value.Value) bool {
	switch op {
	case Eq:
		return value.Equal(x, v)
	case Ne:
		return !value.Equal(x, v)
	}
	c, ok := value.Compare(x, v)
	if !ok {
		return false
	}
	switch op {
	case Lt:
		return c < 0
	case Le:
		return c <= 0
	case Gt:
		return c > 0
	default:
		return c >= 0
	}
}
