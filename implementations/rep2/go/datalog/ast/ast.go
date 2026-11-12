// Package ast defines the syntax tree of a Datalog program with stratified
// negation, together with the total order on constants shared by comparison
// built-ins and by query output.
package ast

import (
	"strconv"
	"strings"
)

// Constant is a Datalog constant: either an integer or a symbol (an
// identifier such as "alice"). Constants are comparable and may be used as
// map keys.
type Constant struct {
	isSym bool
	num   int64
	sym   string
}

// Int returns the integer constant n.
func Int(n int64) Constant { return Constant{num: n} }

// Sym returns the symbolic constant with the given name.
func Sym(name string) Constant { return Constant{isSym: true, sym: name} }

// IsInt reports whether c is an integer constant.
func (c Constant) IsInt() bool { return !c.isSym }

// IntValue returns the value of an integer constant (0 for a symbol).
func (c Constant) IntValue() int64 { return c.num }

// SymValue returns the name of a symbolic constant ("" for an integer).
func (c Constant) SymValue() string { return c.sym }

// String renders the constant in program syntax.
func (c Constant) String() string {
	if c.isSym {
		return c.sym
	}
	return strconv.FormatInt(c.num, 10)
}

// Compare orders constants: every integer precedes every symbol, integers
// compare numerically, symbols compare bytewise. It returns -1, 0 or +1.
func Compare(a, b Constant) int {
	switch {
	case !a.isSym && b.isSym:
		return -1
	case a.isSym && !b.isSym:
		return 1
	case !a.isSym:
		return cmp3(a.num < b.num, a.num > b.num)
	default:
		return strings.Compare(a.sym, b.sym)
	}
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

// Term is a constant or a variable. Each anonymous variable "_" in the source
// is given a distinct generated name (starting with "_"), so that variable
// names alone determine identity within a clause.
type Term struct {
	IsVar bool
	Var   string   // variable name when IsVar
	Const Constant // value when !IsVar
}

// V returns the variable term with the given name.
func V(name string) Term { return Term{IsVar: true, Var: name} }

// C returns the constant term c.
func C(c Constant) Term { return Term{Const: c} }

// String renders the term; generated anonymous variables print as "_".
func (t Term) String() string {
	if !t.IsVar {
		return t.Const.String()
	}
	if strings.HasPrefix(t.Var, "_") {
		return "_"
	}
	return t.Var
}

// PredID identifies a predicate by name and arity together.
type PredID struct {
	Name  string
	Arity int
}

func (p PredID) String() string { return p.Name + "/" + strconv.Itoa(p.Arity) }

// Atom is a predicate applied to terms.
type Atom struct {
	Pred string
	Args []Term
}

// ID returns the predicate identity of the atom.
func (a Atom) ID() PredID { return PredID{a.Pred, len(a.Args)} }

func (a Atom) String() string {
	parts := make([]string, len(a.Args))
	for i, t := range a.Args {
		parts[i] = t.String()
	}
	return a.Pred + "(" + strings.Join(parts, ", ") + ")"
}

// CmpOp is a comparison operator.
type CmpOp int

// The comparison operators of the language.
const (
	EQ CmpOp = iota // =
	NE              // !=
	LT              // <
	LE              // <=
	GT              // >
	GE              // >=
)

var opText = [...]string{"=", "!=", "<", "<=", ">", ">="}

func (o CmpOp) String() string { return opText[o] }

// Holds reports whether "a op b" is true under the constant order; c is the
// result of comparing a with b.
func (o CmpOp) Holds(c int) bool {
	switch o {
	case EQ:
		return c == 0
	case NE:
		return c != 0
	case LT:
		return c < 0
	case LE:
		return c <= 0
	case GT:
		return c > 0
	default:
		return c >= 0
	}
}

// LiteralKind distinguishes the three forms of body literal.
type LiteralKind int

// Literal forms.
const (
	Positive   LiteralKind = iota // q(...)
	Negative                      // not q(...)
	Comparison                    // t1 op t2
)

// Literal is one element of a rule body.
type Literal struct {
	Kind        LiteralKind
	Atom        Atom  // for Positive and Negative
	Op          CmpOp // for comparisons
	Left, Right Term  // for comparisons
}

func (l Literal) String() string {
	switch l.Kind {
	case Positive:
		return l.Atom.String()
	case Negative:
		return "not " + l.Atom.String()
	default:
		return l.Left.String() + " " + l.Op.String() + " " + l.Right.String()
	}
}

// Rule is Head :- Body. A fact is a rule with an empty body.
type Rule struct {
	Head Atom
	Body []Literal
}

func (r Rule) String() string {
	if len(r.Body) == 0 {
		return r.Head.String() + "."
	}
	parts := make([]string, len(r.Body))
	for i, l := range r.Body {
		parts[i] = l.String()
	}
	return r.Head.String() + " :- " + strings.Join(parts, ", ") + "."
}

// Program is a parsed Datalog program: facts and rules (in source order) and
// queries (in source order).
type Program struct {
	Rules   []Rule
	Queries []Atom
}
