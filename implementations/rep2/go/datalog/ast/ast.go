// Package ast defines the in-memory representation of a Datalog program:
// predicates, constants, terms, atoms, literals, rules and queries.
//
// Constants are interned. Program.Consts lists every distinct constant in the
// total order defined by the language (every integer before every identifier,
// integers numerically, identifiers bytewise), and a constant is referred to
// everywhere else by its index in that slice. Comparing two constants is
// therefore a comparison of two small integers.
package ast

import (
	"strconv"
	"strings"
)

// Constant is a Datalog constant: either an integer or an identifier.
type Constant struct {
	IsInt bool
	Int   int64  // value when IsInt
	Name  string // spelling when !IsInt
}

// String returns the canonical textual form of the constant.
func (c Constant) String() string {
	if c.IsInt {
		return strconv.FormatInt(c.Int, 10)
	}
	return c.Name
}

// Compare orders constants: integers before identifiers, integers
// numerically, identifiers by ASCII byte value (a proper prefix sorts first).
// It returns -1, 0 or +1.
func Compare(a, b Constant) int {
	switch {
	case a.IsInt && b.IsInt:
		switch {
		case a.Int < b.Int:
			return -1
		case a.Int > b.Int:
			return 1
		}
		return 0
	case a.IsInt:
		return -1
	case b.IsInt:
		return 1
	}
	return strings.Compare(a.Name, b.Name)
}

// Pred identifies a predicate. Name and arity together are its identity:
// r/1 and r/2 are different predicates.
type Pred struct {
	Name  string
	Arity int
}

// String returns "name/arity".
func (p Pred) String() string { return p.Name + "/" + strconv.Itoa(p.Arity) }

// Term is a variable or a constant. For a variable, ID is a clause-local slot
// number (every anonymous "_" gets a slot of its own); for a constant, ID is
// an index into Program.Consts.
type Term struct {
	IsVar bool
	ID    int
}

// Atom is a predicate applied to arguments. Pred indexes Program.Preds.
type Atom struct {
	Pred int
	Args []Term
}

// CmpOp is a comparison operator.
type CmpOp uint8

// Comparison operators.
const (
	Eq CmpOp = iota
	Ne
	Lt
	Le
	Gt
	Ge
)

var cmpNames = [...]string{"=", "!=", "<", "<=", ">", ">="}

// String returns the operator's source spelling.
func (o CmpOp) String() string { return cmpNames[o] }

// Holds reports whether "a op b" is true for two order-preserving constant ids.
func (o CmpOp) Holds(a, b int32) bool {
	switch o {
	case Eq:
		return a == b
	case Ne:
		return a != b
	case Lt:
		return a < b
	case Le:
		return a <= b
	case Gt:
		return a > b
	}
	return a >= b
}

// LitKind distinguishes the three kinds of body literal.
type LitKind uint8

// Literal kinds.
const (
	Positive   LitKind = iota // p(...)
	Negative                  // not p(...)
	Comparison                // t1 op t2
)

// Literal is one element of a rule body. Atom is used by Positive and
// Negative literals; Op, Left and Right by comparisons.
type Literal struct {
	Kind        LitKind
	Atom        Atom
	Op          CmpOp
	Left, Right Term
}

// Rule is "Head :- Body." A fact is a rule with an empty body. Variables are
// numbered 0..NumVars-1 within the rule.
type Rule struct {
	Head    Atom
	Body    []Literal
	NumVars int
}

// Program is a parsed Datalog program.
type Program struct {
	Preds   []Pred     // predicate table, indexed by Atom.Pred
	Consts  []Constant // constants in ascending order, indexed by Term.ID
	Rules   []Rule     // facts and rules, in source order
	Queries []Atom     // queries, in source order
}
