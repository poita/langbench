package scheme

// Frame is a heap environment frame: a parent pointer plus parallel slices of
// symbol ids and values. The id slice is often shared with a procedure
// descriptor and has capacity == length, so the first append (a `define`)
// copies it. The global environment is not a Frame (it is the nil parent).
type Frame struct {
	parent *Frame
	ids    []int32
	vals   []Value
}

// lookup finds the value of symbol id: innermost frame first, then globals.
func (in *Interp) lookup(id int32, env *Frame) Value {
	for f := env; f != nil; f = f.parent {
		for i, x := range f.ids {
			if x == id {
				return f.vals[i]
			}
		}
	}
	v := in.globals[id]
	if v.t == tUnbound {
		throw(ErrUnboundVariable)
	}
	return v
}

// assign implements set!: it updates the nearest enclosing binding.
func (in *Interp) assign(id int32, env *Frame, v Value) {
	for f := env; f != nil; f = f.parent {
		for i, x := range f.ids {
			if x == id {
				f.vals[i] = v
				return
			}
		}
	}
	if in.globals[id].t == tUnbound {
		throw(ErrUnboundVariable)
	}
	in.globals[id] = v
}

// define binds id in the innermost frame (the global frame when env is nil),
// replacing an existing binding of the same name in that frame.
func (in *Interp) define(id int32, env *Frame, v Value) {
	if env == nil {
		in.globals[id] = v
		return
	}
	for i, x := range env.ids {
		if x == id {
			env.vals[i] = v
			return
		}
	}
	env.ids = append(env.ids, id)
	env.vals = append(env.vals, v)
}
