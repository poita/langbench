package ast

import (
	"strconv"
	"strings"
)

// Pred identifies a predicate by name and arity: r/1 and r/2 are different
// predicates.
type Pred struct {
	Name  string
	Arity int
}

// String formats the predicate as name/arity.
func (p Pred) String() string { return p.Name + "/" + strconv.Itoa(p.Arity) }

// Term is a constant or a variable. Anonymous variables (`_`) are represented
// as variables with unique names beginning with `_`; the parser makes every
// occurrence distinct.
type Term struct {
	IsVar bool
	Name  string // variable name, if IsVar
	Value Value  // constant, if !IsVar
}

// Var returns a variable term.
func Var(name string) Term { return Term{IsVar: true, Name: name} }

// Const returns a constant term.
func Const(v Value) Term { return Term{Value: v} }

// IsAnon reports whether t is an anonymous variable.
func (t Term) IsAnon() bool { return t.IsVar && strings.HasPrefix(t.Name, "_") }

// String formats the term in source syntax.
func (t Term) String() string {
	switch {
	case t.IsAnon():
		return "_"
	case t.IsVar:
		return t.Name
	}
	return t.Value.String()
}

// Atom is a predicate applied to terms.
type Atom struct {
	Name string
	Args []Term
}

// Pred returns the predicate of the atom.
func (a Atom) Pred() Pred { return Pred{a.Name, len(a.Args)} }

// String formats the atom in source syntax.
func (a Atom) String() string {
	var sb strings.Builder
	sb.WriteString(a.Name)
	sb.WriteByte('(')
	for i, t := range a.Args {
		if i > 0 {
			sb.WriteString(", ")
		}
		sb.WriteString(t.String())
	}
	sb.WriteByte(')')
	return sb.String()
}

// CmpOp is a comparison operator.
type CmpOp int

// Comparison operators.
const (
	Eq CmpOp = iota // =
	Ne              // !=
	Lt              // <
	Le              // <=
	Gt              // >
	Ge              // >=
)

var cmpNames = [...]string{"=", "!=", "<", "<=", ">", ">="}

// String returns the operator's source form.
func (o CmpOp) String() string { return cmpNames[o] }

// Holds reports whether a relation with three-way comparison result c
// (negative, zero, positive) satisfies the operator.
func (o CmpOp) Holds(c int) bool {
	switch o {
	case Eq:
		return c == 0
	case Ne:
		return c != 0
	case Lt:
		return c < 0
	case Le:
		return c <= 0
	case Gt:
		return c > 0
	}
	return c >= 0
}

// LitKind distinguishes the three forms of body literal.
type LitKind int

// Literal kinds.
const (
	Positive   LitKind = iota // p(...)
	Negative                  // not p(...)
	Comparison                // t1 op t2
)

// Literal is one element of a rule body. Atom is set for Positive and
// Negative literals; Op, Left and Right for Comparison literals.
type Literal struct {
	Kind        LitKind
	Atom        Atom
	Op          CmpOp
	Left, Right Term
}

// String formats the literal in source syntax.
func (l Literal) String() string {
	switch l.Kind {
	case Positive:
		return l.Atom.String()
	case Negative:
		return "not " + l.Atom.String()
	}
	return l.Left.String() + " " + l.Op.String() + " " + l.Right.String()
}

// Rule is a head atom derived from a body of literals. A fact is a rule with
// an empty body.
type Rule struct {
	Head Atom
	Body []Literal
	Line int // 1-based source line of the clause, 0 if unknown
}

// IsFact reports whether the rule has an empty body.
func (r Rule) IsFact() bool { return len(r.Body) == 0 }

// String formats the rule in source syntax.
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

// Program is a parsed Datalog program: facts and rules in source order, and
// queries in source order.
type Program struct {
	Rules   []Rule
	Queries []Atom
}
