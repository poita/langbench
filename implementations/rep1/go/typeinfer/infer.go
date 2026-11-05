package typeinfer

import "example.com/typeinfer/syntax"

// infer returns the type of expression e. It is Algorithm J: a single
// left-to-right recursive pass that unifies as it goes.
func (c *Checker) infer(e int32) int32 {
	n := &c.prog.Nodes[e]
	switch n.Kind {
	case syntax.KInt:
		return tInt
	case syntax.KBool:
		return tBool
	case syntax.KUnit:
		return tUnit
	case syntax.KVar:
		i := c.top[n.Name]
		if i < 0 {
			fail(ErrUnbound)
		}
		b := c.binds[i]
		if !b.poly {
			return b.typ
		}
		return c.instantiate(b.typ)
	case syntax.KFun:
		v := c.newVar(c.level)
		c.push(n.Name, v, false)
		body := c.infer(n.A)
		c.pop()
		return c.newArrow(v, body)
	case syntax.KApp:
		f := c.infer(n.A)
		a := c.infer(n.B)
		if f = c.find(f); c.nodes[f].kind == kArrow {
			// unify (p -> q) with (a -> fresh): the fresh result variable
			// would just be bound to q.
			c.unify(c.nodes[f].a, a)
			return c.nodes[f].b
		}
		r := c.newVar(c.level)
		c.unify(f, c.newArrow(a, r))
		return r
	case syntax.KLet:
		c.level++
		t := c.infer(n.A)
		c.level--
		poly := c.generalize(t)
		c.push(n.Name, t, poly)
		r := c.infer(n.B)
		c.pop()
		return r
	case syntax.KLetRec:
		t, poly := c.inferRec(n.Name, n.A)
		c.push(n.Name, t, poly)
		r := c.infer(n.B)
		c.pop()
		return r
	case syntax.KIf:
		cond := c.infer(n.A)
		c.unify(cond, tBool)
		a := c.infer(n.B)
		b := c.infer(n.C)
		c.unify(a, b)
		return a
	case syntax.KTuple:
		cnt := n.B
		start := c.reservePool(cnt)
		for i := int32(0); i < cnt; i++ {
			c.pool[start+i] = c.infer(c.prog.Kids[n.A+i])
		}
		return c.newTuple(start, cnt)
	case syntax.KList:
		elem := c.newVar(c.level)
		for i := int32(0); i < n.B; i++ {
			c.unify(elem, c.infer(c.prog.Kids[n.A+i]))
		}
		return c.newList(elem)
	case syntax.KCons:
		h := c.infer(n.A)
		t := c.infer(n.B)
		c.unify(t, c.newList(h))
		return t
	case syntax.KBinop:
		operand, result := tInt, tInt
		switch {
		case n.Op.IsCompare():
			result = tBool
		case n.Op.IsLogic():
			operand, result = tBool, tBool
		}
		c.unify(c.infer(n.A), operand)
		c.unify(c.infer(n.B), operand)
		return result
	}
	panic("typeinfer: unknown node kind")
}

// inferRec infers the right-hand side rhs of "let rec name = rhs" at the next
// level, with name bound monomorphically to a fresh variable, and generalises
// the result. The binding is not left in the environment.
func (c *Checker) inferRec(name, rhs int32) (typ int32, poly bool) {
	c.level++
	fv := c.newVar(c.level)
	c.push(name, fv, false)
	t := c.infer(rhs)
	c.unify(fv, t)
	c.pop()
	c.level--
	return fv, c.generalize(fv)
}
