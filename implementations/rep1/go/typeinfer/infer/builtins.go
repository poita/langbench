package infer

import "github.com/example/typeinfer/types"

// builtins returns the initial environment's schemes.
func builtins(c *types.Context) map[string]*types.Scheme {
	arrow, list := types.Arrow, types.List
	pair := func(a, b *types.Type) *types.Type { return types.Tuple([]*types.Type{a, b}) }
	out := make(map[string]*types.Scheme)
	// def builds a type one level up with fresh variables a, b, c and
	// generalises it.
	def := func(name string, build func(a, b *types.Type) *types.Type) {
		c.EnterLevel()
		t := build(c.NewVar(), c.NewVar())
		c.LeaveLevel()
		out[name] = c.Generalize(t)
	}
	def("not", func(a, b *types.Type) *types.Type { return arrow(types.Bool, types.Bool) })
	def("fst", func(a, b *types.Type) *types.Type { return arrow(pair(a, b), a) })
	def("snd", func(a, b *types.Type) *types.Type { return arrow(pair(a, b), b) })
	def("hd", func(a, b *types.Type) *types.Type { return arrow(list(a), a) })
	def("tl", func(a, b *types.Type) *types.Type { return arrow(list(a), list(a)) })
	def("null", func(a, b *types.Type) *types.Type { return arrow(list(a), types.Bool) })
	def("length", func(a, b *types.Type) *types.Type { return arrow(list(a), types.Int) })
	def("map", func(a, b *types.Type) *types.Type {
		return arrow(arrow(a, b), arrow(list(a), list(b)))
	})
	def("fold", func(a, b *types.Type) *types.Type {
		return arrow(arrow(a, arrow(b, a)), arrow(a, arrow(list(b), a)))
	})
	return out
}
