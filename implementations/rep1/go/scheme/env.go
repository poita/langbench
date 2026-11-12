package scheme

// Env is an environment frame. Local frames hold a few parallel
// symbol/value slices searched linearly; the root frame holds the global
// bindings in a map.
type Env struct {
	parent *Env
	syms   []*Symbol
	vals   []Value
	global map[*Symbol]Value
}

func newGlobalEnv() *Env {
	return &Env{global: make(map[*Symbol]Value)}
}

// lookup finds the innermost binding of s.
func (e *Env) lookup(s *Symbol) (Value, bool) {
	for f := e; f != nil; f = f.parent {
		if f.global != nil {
			v, ok := f.global[s]
			return v, ok
		}
		for i, x := range f.syms {
			if x == s {
				return f.vals[i], true
			}
		}
	}
	return nil, false
}

// define binds s in this very frame, replacing an existing binding there.
func (e *Env) define(s *Symbol, v Value) {
	if e.global != nil {
		e.global[s] = v
		return
	}
	for i, x := range e.syms {
		if x == s {
			e.vals[i] = v
			return
		}
	}
	e.syms = append(e.syms, s)
	e.vals = append(e.vals, v)
}

// set assigns to the nearest existing binding of s.
func (e *Env) set(s *Symbol, v Value) bool {
	for f := e; f != nil; f = f.parent {
		if f.global != nil {
			if _, ok := f.global[s]; ok {
				f.global[s] = v
				return true
			}
			return false
		}
		for i, x := range f.syms {
			if x == s {
				f.vals[i] = v
				return true
			}
		}
	}
	return false
}
