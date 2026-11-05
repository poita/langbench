package vm

func init() {
	register("mapNew", func(m *VM, a []Value) Value { return MapV(NewMap()) })
	register("mapLen", func(m *VM, a []Value) Value { return Int(int64(a[0].P.M.live)) })
	register("mapHas", func(m *VM, a []Value) Value { return Bool(a[0].P.M.Has(a[1])) })
	register("mapGet", func(m *VM, a []Value) Value {
		if v, ok := a[0].P.M.Get(a[1]); ok {
			return Some(v)
		}
		return NoneV
	})
	register("mapGetOr", func(m *VM, a []Value) Value {
		if v, ok := a[0].P.M.Get(a[1]); ok {
			return v
		}
		return a[2]
	})
	register("mapSet", func(m *VM, a []Value) Value {
		a[0].P.M.Set(a[1], a[2])
		return Unit
	})
	register("mapDel", func(m *VM, a []Value) Value { return Bool(a[0].P.M.Del(a[1])) })
	register("keysOf", func(m *VM, a []Value) Value {
		mp := a[0].P.M
		out := make([]Value, 0, mp.live)
		for i := range mp.ents {
			if e := &mp.ents[i]; !e.dead {
				out = append(out, e.K)
			}
		}
		return List(out)
	})
	register("valuesOf", func(m *VM, a []Value) Value {
		mp := a[0].P.M
		out := make([]Value, 0, mp.live)
		for i := range mp.ents {
			if e := &mp.ents[i]; !e.dead {
				out = append(out, e.V)
			}
		}
		return List(out)
	})
	register("pairsOf", func(m *VM, a []Value) Value {
		mp := a[0].P.M
		out := make([]Value, 0, mp.live)
		for i := range mp.ents {
			if e := &mp.ents[i]; !e.dead {
				out = append(out, Tuple([]Value{e.K, e.V}))
			}
		}
		return List(out)
	})
	register("mapClear", func(m *VM, a []Value) Value {
		a[0].P.M.Clear()
		return Unit
	})
	register("mapCopy", func(m *VM, a []Value) Value { return MapV(a[0].P.M.Copy()) })
}
