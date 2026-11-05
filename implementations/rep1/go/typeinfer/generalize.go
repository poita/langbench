package typeinfer

// generalize quantifies, in place, every unbound variable reachable from t
// whose level is deeper than the current level. It reports whether it
// quantified at least one variable (if not, the type is monomorphic and
// instantiating it is the identity).
func (c *Checker) generalize(t int32) bool {
	return c.gen(t, c.newStamp())
}

func (c *Checker) gen(t int32, stamp uint64) bool {
	t = c.find(t)
	n := &c.nodes[t]
	switch n.kind {
	case kVar:
		if n.level > c.level {
			n.level = genericLevel
			return true
		}
	case kArrow:
		if n.stamp == stamp {
			return false
		}
		n.stamp = stamp
		a, b := n.a, n.b
		x := c.gen(a, stamp)
		y := c.gen(b, stamp)
		return x || y
	case kList:
		if n.stamp == stamp {
			return false
		}
		n.stamp = stamp
		return c.gen(n.a, stamp)
	case kTuple:
		if n.stamp == stamp {
			return false
		}
		n.stamp = stamp
		start, cnt := n.a, n.b
		found := false
		for i := int32(0); i < cnt; i++ {
			if c.gen(c.pool[start+i], stamp) {
				found = true
			}
		}
		return found
	}
	return false
}

// instantiate returns a copy of the scheme t in which every quantified
// variable is replaced by a fresh variable at the current level. Sub-terms
// without quantified variables are shared with the original, and every node
// is copied at most once per call, so the sharing of the scheme is kept.
func (c *Checker) instantiate(t int32) int32 {
	return c.inst(t, c.newStamp())
}

func (c *Checker) inst(t int32, stamp uint64) int32 {
	t = c.find(t)
	n := &c.nodes[t]
	switch n.kind {
	case kVar:
		if n.level != genericLevel {
			return t
		}
		if n.stamp == stamp {
			return n.memo
		}
		v := c.newVar(c.level)
		n = &c.nodes[t]
		n.stamp, n.memo = stamp, v
		return v
	case kArrow:
		if n.stamp == stamp {
			return n.memo
		}
		a, b := n.a, n.b
		ra := c.inst(a, stamp)
		rb := c.inst(b, stamp)
		res := t
		if ra != c.find(a) || rb != c.find(b) {
			res = c.newArrow(ra, rb)
		}
		n = &c.nodes[t]
		n.stamp, n.memo = stamp, res
		return res
	case kList:
		if n.stamp == stamp {
			return n.memo
		}
		a := n.a
		ra := c.inst(a, stamp)
		res := t
		if ra != c.find(a) {
			res = c.newList(ra)
		}
		n = &c.nodes[t]
		n.stamp, n.memo = stamp, res
		return res
	case kTuple:
		if n.stamp == stamp {
			return n.memo
		}
		start, cnt := n.a, n.b
		var fresh int32 = -1 // start of the new component list, once needed
		for i := int32(0); i < cnt; i++ {
			child := c.pool[start+i]
			r := c.inst(child, stamp)
			if fresh < 0 {
				if r == c.find(child) {
					continue
				}
				// First changed component: allocate the new list and copy
				// the (unchanged) components before it.
				fresh = c.reservePool(cnt)
				for j := int32(0); j < i; j++ {
					c.pool[fresh+j] = c.find(c.pool[start+j])
				}
			}
			c.pool[fresh+i] = r
		}
		res := t
		if fresh >= 0 {
			res = c.newTuple(fresh, cnt)
		}
		n = &c.nodes[t]
		n.stamp, n.memo = stamp, res
		return res
	}
	return t
}
