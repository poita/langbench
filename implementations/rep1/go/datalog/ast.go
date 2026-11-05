package datalog

import (
	"errors"
	"fmt"
	"strconv"
)

// Constant is a Datalog constant: either an integer or a symbol
// (an identifier such as "alice").
type Constant struct {
	IsInt bool
	Int   int64  // valid when IsInt
	Sym   string // valid when !IsInt
}

// Int returns the integer constant n.
func Int(n int64) Constant { return Constant{IsInt: true, Int: n} }

// Sym returns the symbolic constant s.
func Sym(s string) Constant { return Constant{Sym: s} }

// String returns the source form of c: canonical decimal or the identifier.
func (c Constant) String() string {
	if c.IsInt {
		return strconv.FormatInt(c.Int, 10)
	}
	return c.Sym
}

// Compare orders constants: every integer is less than every symbol, integers
// compare numerically and symbols bytewise. It returns -1, 0 or +1.
func (c Constant) Compare(o Constant) int {
	switch {
	case c.IsInt && o.IsInt:
		return cmp3(c.Int < o.Int, c.Int > o.Int)
	case c.IsInt:
		return -1
	case o.IsInt:
		return 1
	}
	switch {
	case c.Sym < o.Sym:
		return -1
	case c.Sym > o.Sym:
		return 1
	}
	return 0
}

func cmp3(less, greater bool) int {
	if less {
		return -1
	}
	if greater {
		return 1
	}
	return 0
}

// Predicate identifies a relation by name and arity.
type Predicate struct {
	Name  string
	Arity int
}

// Term is an argument of an atom or a comparison operand.
//
// If IsVar is set, Index is the variable's slot, numbered from zero within its
// clause (each anonymous "_" gets its own slot). Otherwise Index is the rank of
// the constant in [Program.Consts].
type Term struct {
	IsVar bool
	Index int
}

// Atom is a predicate applied to terms. Pred indexes [Program.Preds].
type Atom struct {
	Pred int
	Args []Term
}

// LiteralKind distinguishes the three forms of body literal.
type LiteralKind uint8

const (
	// Positive is an atom that must hold.
	Positive LiteralKind = iota
	// Negative is a negated atom ("not p(X)").
	Negative
	// Comparison is a built-in comparison between two terms.
	Comparison
)

// CmpOp is a comparison operator.
type CmpOp uint8

// The comparison operators.
const (
	OpEq CmpOp = iota // =
	OpNe              // !=
	OpLt              // <
	OpLe              // <=
	OpGt              // >
	OpGe              // >=
)

func (o CmpOp) String() string {
	return [...]string{"=", "!=", "<", "<=", ">", ">="}[o]
}

// holds reports whether "a op b" is true for order-preserving constant ids.
func (o CmpOp) holds(a, b int32) bool {
	switch o {
	case OpEq:
		return a == b
	case OpNe:
		return a != b
	case OpLt:
		return a < b
	case OpLe:
		return a <= b
	case OpGt:
		return a > b
	}
	return a >= b
}

// Literal is one element of a rule body. For Positive and Negative literals
// Atom is set; for Comparison literals Op, Left and Right are set.
type Literal struct {
	Kind        LiteralKind
	Atom        Atom
	Op          CmpOp
	Left, Right Term
}

// Rule is a clause "head :- body". A fact is a rule with an empty body.
type Rule struct {
	Head    Atom
	Body    []Literal
	NumVars int // number of variable slots used by the clause
	Line    int // source line of the clause, for diagnostics
}

// IsFact reports whether the rule has an empty body.
func (r *Rule) IsFact() bool { return len(r.Body) == 0 }

// Query is a clause "?- atom."
type Query struct {
	Atom    Atom
	NumVars int
	Line    int
}

// Program is a parsed Datalog program.
//
// Consts is sorted in the constant order, and constant terms refer to it by
// index, so comparing two constant ids compares the constants.
type Program struct {
	Consts  []Constant
	Preds   []Predicate
	Rules   []Rule // facts and rules, in source order
	Queries []Query
}

// Errors reported for programs that parse but are not valid.
var (
	// ErrUnsafe is returned for a rule in which a variable of the head, a
	// negated atom or a comparison does not occur in a positive body atom.
	ErrUnsafe = errors.New("datalog: unsafe rule")
	// ErrNotStratifiable is returned when a dependency cycle contains a
	// negative edge.
	ErrNotStratifiable = errors.New("datalog: program is not stratifiable")
)

// SyntaxError describes malformed input.
type SyntaxError struct {
	Line, Col int
	Msg       string
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("datalog: syntax error at %d:%d: %s", e.Line, e.Col, e.Msg)
}
