package types

import "errors"

// Errors returned by [Context.Unify].
var (
	// ErrUnify reports that two types have different constructors or
	// shapes (int against bool, tuples of different arity, ...).
	ErrUnify = errors.New("cannot unify types")
	// ErrOccurs reports that unification would build an infinite type.
	ErrOccurs = errors.New("occurs check failed: infinite type")
)

// Context holds the state shared by the operations on one family of types:
// the current generalisation level, the supply of fresh variables and the
// visit stamps that make graph walks visit each node once.
type Context struct {
	level  int32
	nextID int32
	stamp  uint32
}

// NewContext returns a Context at level 0.
func NewContext() *Context { return &Context{} }

// Level returns the current generalisation level.
func (c *Context) Level() int { return int(c.level) }

// EnterLevel increases the current level by one. Type variables created
// while the level is raised can be generalised once it is lowered again.
func (c *Context) EnterLevel() { c.level++ }

// LeaveLevel decreases the current level by one.
func (c *Context) LeaveLevel() { c.level-- }

// NewVar returns a fresh unbound type variable at the current level.
func (c *Context) NewVar() *Type {
	c.nextID++
	return &Type{kind: KindVar, level: c.level, id: c.nextID}
}

// newStamp starts a new graph walk.
func (c *Context) newStamp() uint32 {
	c.stamp++
	return c.stamp
}

// Unify makes a and b equal by binding type variables, or returns
// [ErrUnify] or [ErrOccurs]. Components are unified left to right, each
// completely before the next, and the occurs check runs whenever a variable is
// about to be bound. On failure the types may be partly unified.
//
// Variables are bound with a union-find link; whenever two constructors turn
// out to be equal they are linked as well, so that shared sub-terms are never
// unified twice and unifying DAGs does not blow up. Unification lowers the
// level of every variable of a type that is bound to a variable of a lower
// level.
func (c *Context) Unify(a, b *Type) error {
	a, b = find(a), find(b)
	if a == b {
		return nil
	}
	if a.kind == KindVar {
		return c.bind(a, b)
	}
	if b.kind == KindVar {
		return c.bind(b, a)
	}
	if a.kind != b.kind || len(a.args) != len(b.args) {
		return ErrUnify
	}
	for i, x := range a.args {
		if err := c.Unify(x, b.args[i]); err != nil {
			return err
		}
	}
	// Everything below is now identical: remember it. This happens only on
	// success so that a failed unification never merges unequal nodes that
	// might be shared with the environment.
	if a.kind >= KindArrow {
		a.link = b
	}
	return nil
}

// bind binds the unbound variable v to t after an occurs check that also
// lowers the levels of the variables of t to the level of v.
func (c *Context) bind(v, t *Type) error {
	if c.occursAdjust(v, t, v.level, c.newStamp()) {
		return ErrOccurs
	}
	v.link = t
	return nil
}

// occursAdjust reports whether v occurs in t, lowering to level every
// variable of t whose level is higher. Each distinct node is visited once.
func (c *Context) occursAdjust(v, t *Type, level int32, stamp uint32) bool {
	t = find(t)
	switch t.kind {
	case KindVar:
		if t == v {
			return true
		}
		if t.level > level {
			t.level = level
		}
		return false
	case KindInt, KindBool, KindUnit:
		return false
	}
	if t.mark == stamp {
		return false
	}
	t.mark = stamp
	for _, a := range t.args {
		if c.occursAdjust(v, a, level, stamp) {
			return true
		}
	}
	return false
}

// Generalize quantifies every unbound variable of t whose level is greater
// than the current level and returns the resulting scheme (level-based
// generalisation). It does not look at any environment. It visits each
// distinct node of t once. Quantified variables are marked in place, so t must
// not be used monomorphically afterwards.
func (c *Context) Generalize(t *Type) *Scheme {
	poly := false
	stamp := c.newStamp()
	var walk func(t *Type)
	walk = func(t *Type) {
		t = find(t)
		switch t.kind {
		case KindVar:
			if t.level > c.level {
				t.level = genericLevel
			}
			if t.level == genericLevel {
				poly = true
			}
			return
		case KindInt, KindBool, KindUnit:
			return
		}
		if t.mark == stamp {
			return
		}
		t.mark = stamp
		for _, a := range t.args {
			walk(a)
		}
	}
	walk(t)
	return &Scheme{Type: t, Poly: poly}
}

// Instantiate returns a copy of s.Type in which every quantified variable is
// replaced by a fresh variable at the current level. A monomorphic scheme is
// returned as is, in O(1). Otherwise each distinct node of the scheme is
// visited once, copies preserve the sharing of the original, and sub-terms
// that contain no quantified variable are shared with the original rather than
// copied.
func (c *Context) Instantiate(s *Scheme) *Type {
	if !s.Poly {
		return s.Type
	}
	return c.instantiate(s.Type, c.newStamp())
}

func (c *Context) instantiate(t *Type, stamp uint32) *Type {
	t = find(t)
	switch t.kind {
	case KindVar:
		if t.level != genericLevel {
			return t
		}
		if t.mark == stamp {
			return t.copy
		}
		nv := c.NewVar()
		t.mark, t.copy = stamp, nv
		return nv
	case KindInt, KindBool, KindUnit:
		return t
	}
	if t.mark == stamp {
		return t.copy
	}
	var args []*Type // allocated on the first component that changes
	for i, a := range t.args {
		a = find(a)
		n := c.instantiate(a, stamp)
		if n != a && args == nil {
			args = make([]*Type, len(t.args))
			for j := 0; j < i; j++ {
				args[j] = find(t.args[j])
			}
		}
		if args != nil {
			args[i] = n
		}
	}
	res := t
	if args != nil {
		res = &Type{kind: t.kind, args: args}
	}
	t.mark, t.copy = stamp, res
	return res
}
