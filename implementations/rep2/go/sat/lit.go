package sat

// Var identifies a propositional variable. Variables are numbered from 0 in
// the order they are created by [Solver.NewVar].
type Var int32

// Lit is a literal: a variable or its negation. The encoding is 2*v for the
// positive literal of v and 2*v+1 for the negative one.
type Lit int32

// litUndef is a sentinel that is never a valid literal.
const litUndef Lit = -1

// MkLit returns the literal of variable v, negated if neg is true.
func MkLit(v Var, neg bool) Lit {
	l := Lit(v) << 1
	if neg {
		l |= 1
	}
	return l
}

// FromDIMACS converts a non-zero DIMACS integer (k for variable k-1 positive,
// -k for it negated) to a Lit. It panics if k is zero.
func FromDIMACS(k int) Lit {
	switch {
	case k > 0:
		return MkLit(Var(k-1), false)
	case k < 0:
		return MkLit(Var(-k-1), true)
	}
	panic("sat: FromDIMACS(0)")
}

// Var returns the variable of the literal.
func (l Lit) Var() Var { return Var(l >> 1) }

// Negated reports whether the literal is a negative occurrence of its variable.
func (l Lit) Negated() bool { return l&1 == 1 }

// Not returns the complementary literal.
func (l Lit) Not() Lit { return l ^ 1 }

// DIMACS returns the literal as a DIMACS integer (variable numbers from 1).
func (l Lit) DIMACS() int {
	if l.Negated() {
		return -(int(l.Var()) + 1)
	}
	return int(l.Var()) + 1
}

// Truth values of variables and literals during search.
const (
	lFalse int8 = -1
	lUndef int8 = 0
	lTrue  int8 = 1
)
