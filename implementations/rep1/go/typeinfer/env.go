package typeinfer

// The environment is one stack of bindings plus, for every interned name, the
// index of that name's innermost binding. Entering a scope pushes; leaving it
// pops in LIFO order, restoring the previous binding of the name. Lookup is a
// slice index and does not depend on how many names are in scope.

type binding struct {
	typ  int32 // type (a scheme if poly)
	prev int32 // index of the shadowed binding of the same name, or -1
	name int32
	poly bool // may contain quantified variables
}

// ensureNames grows the per-name table to cover n interned names.
func (c *Checker) ensureNames(n int) {
	for len(c.top) < n {
		c.top = append(c.top, -1)
	}
}

func (c *Checker) push(name, typ int32, poly bool) {
	c.binds = append(c.binds, binding{typ: typ, prev: c.top[name], name: name, poly: poly})
	c.top[name] = int32(len(c.binds) - 1)
}

func (c *Checker) pop() {
	b := c.binds[len(c.binds)-1]
	c.top[b.name] = b.prev
	c.binds = c.binds[:len(c.binds)-1]
}

// unwind pops bindings until only mark remain.
func (c *Checker) unwind(mark int) {
	for len(c.binds) > mark {
		c.pop()
	}
}
