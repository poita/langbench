package typeinfer

// installBuiltins binds the initial environment. Each scheme is built with
// its variables already quantified.
func (c *Checker) installBuiltins() {
	gv := func() int32 { return c.newVar(genericLevel) }
	arrow := c.newArrow
	list := c.newList
	pair := func(x, y int32) int32 {
		s := c.reservePool(2)
		c.pool[s], c.pool[s+1] = x, y
		return c.newTuple(s, 2)
	}
	def := func(name string, t int32) {
		id := c.names.Intern(name)
		c.ensureNames(int(id) + 1)
		c.push(id, t, true)
	}

	def("not", arrow(tBool, tBool))
	{
		a, b := gv(), gv()
		def("fst", arrow(pair(a, b), a))
	}
	{
		a, b := gv(), gv()
		def("snd", arrow(pair(a, b), b))
	}
	{
		a := gv()
		def("hd", arrow(list(a), a))
	}
	{
		a := gv()
		def("tl", arrow(list(a), list(a)))
	}
	{
		a := gv()
		def("null", arrow(list(a), tBool))
	}
	{
		a := gv()
		def("length", arrow(list(a), tInt))
	}
	{
		a, b := gv(), gv()
		def("map", arrow(arrow(a, b), arrow(list(a), list(b))))
	}
	{
		a, b := gv(), gv()
		def("fold", arrow(arrow(a, arrow(b, a)), arrow(a, arrow(list(b), a))))
	}
}
