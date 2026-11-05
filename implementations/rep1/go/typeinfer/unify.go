package typeinfer

// unify makes a and b equal, aborting the declaration with ErrUnify or
// ErrOccurs on failure. Children are unified left to right, each fully
// before the next.
func (c *Checker) unify(a, b int32) {
	a, b = c.find(a), c.find(b)
	if a == b {
		return
	}
	ka, kb := c.nodes[a].kind, c.nodes[b].kind
	if ka == kVar {
		c.bind(a, b)
		return
	}
	if kb == kVar {
		c.bind(b, a)
		return
	}
	if ka != kb {
		fail(ErrUnify)
	}
	switch ka {
	case kArrow:
		a1, a2 := c.nodes[a].a, c.nodes[a].b
		b1, b2 := c.nodes[b].a, c.nodes[b].b
		c.unify(a1, b1)
		c.unify(a2, b2)
	case kList:
		c.unify(c.nodes[a].a, c.nodes[b].a)
	case kTuple:
		n := c.nodes[a].b
		if n != c.nodes[b].b {
			fail(ErrUnify)
		}
		pa, pb := c.nodes[a].a, c.nodes[b].a
		for i := int32(0); i < n; i++ {
			c.unify(c.pool[pa+i], c.pool[pb+i])
		}
	}
	// int, bool, unit are singletons, so equal kinds mean a == b.
}

// bind links the unbound variable v to t (a representative other than v).
// The occurs check and the level adjustment are one walk over t.
func (c *Checker) bind(v, t int32) {
	level := c.nodes[v].level
	if c.nodes[t].kind == kVar {
		if c.nodes[t].level > level {
			c.nodes[t].level = level
		}
	} else {
		c.adjust(v, level, t, c.newStamp())
	}
	c.nodes[v].a = t
}

// adjust fails with ErrOccurs if v occurs in t, and lowers the level of every
// variable in t to at most level. Each compound node is visited once.
func (c *Checker) adjust(v, level, t int32, stamp uint64) {
	t = c.find(t)
	n := &c.nodes[t]
	switch n.kind {
	case kVar:
		if t == v {
			fail(ErrOccurs)
		}
		if n.level > level {
			n.level = level
		}
	case kArrow:
		if n.stamp == stamp {
			return
		}
		n.stamp = stamp
		a, b := n.a, n.b
		c.adjust(v, level, a, stamp)
		c.adjust(v, level, b, stamp)
	case kList:
		if n.stamp == stamp {
			return
		}
		n.stamp = stamp
		c.adjust(v, level, n.a, stamp)
	case kTuple:
		if n.stamp == stamp {
			return
		}
		n.stamp = stamp
		start, cnt := n.a, n.b
		for i := int32(0); i < cnt; i++ {
			c.adjust(v, level, c.pool[start+i], stamp)
		}
	}
}
