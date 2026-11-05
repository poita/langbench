package vm

func init() {
	register("print", func(m *VM, a []Value) Value {
		m.WriteRunes(a[0].P.S)
		m.writeByte('\n')
		return Unit
	})
	register("emit", func(m *VM, a []Value) Value {
		m.WriteRunes(a[0].P.S)
		return Unit
	})
	register("panic", func(m *VM, a []Value) Value {
		m.Panic(string(a[0].P.S))
		return Unit
	})

	register("isSome", func(m *VM, a []Value) Value { return Bool(a[0].P.Var == VarSome) })
	register("isNone", func(m *VM, a []Value) Value { return Bool(a[0].P.Var == VarNone) })
	register("unwrap", func(m *VM, a []Value) Value {
		o := a[0].P
		if o.Var != VarSome {
			m.Panic("unwrap of None")
		}
		return o.V[0]
	})
	register("unwrapOr", func(m *VM, a []Value) Value {
		o := a[0].P
		if o.Var != VarSome {
			return a[1]
		}
		return o.V[0]
	})
	register("isOk", func(m *VM, a []Value) Value { return Bool(a[0].P.Var == VarOk) })
	register("isErr", func(m *VM, a []Value) Value { return Bool(a[0].P.Var == VarErr) })
	register("unwrapOk", func(m *VM, a []Value) Value {
		o := a[0].P
		if o.Var != VarOk {
			m.Panic("unwrap of Err")
		}
		return o.V[0]
	})
	register("unwrapErr", func(m *VM, a []Value) Value {
		o := a[0].P
		if o.Var != VarErr {
			m.Panic("unwrap of Ok")
		}
		return o.V[0]
	})
	register("fst", func(m *VM, a []Value) Value { return a[0].P.V[0] })
	register("snd", func(m *VM, a []Value) Value { return a[0].P.V[1] })
}
