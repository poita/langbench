package template

// scope is a lexical scope: a small array of bindings (or, for the root
// scope, the context dict) plus a parent pointer. Lookup walks the chain.
type scope struct {
	parent *scope
	root   *Dict
	names  []string
	vals   []Value
}

func newScope(parent *scope) *scope { return &scope{parent: parent} }

func (s *scope) lookup(name string) (Value, bool) {
	for sc := s; sc != nil; sc = sc.parent {
		if sc.root != nil {
			if v, ok := sc.root.Get(name); ok {
				return v, true
			}
			continue
		}
		for i := len(sc.names) - 1; i >= 0; i-- {
			if sc.names[i] == name {
				if v := sc.vals[i]; v != unbound {
					return v, true
				}
			}
		}
	}
	return nil, false
}

// set binds name in this scope only.
func (s *scope) set(name string, v Value) {
	for i := len(s.names) - 1; i >= 0; i-- {
		if s.names[i] == name {
			s.vals[i] = v
			return
		}
	}
	s.names = append(s.names, name)
	s.vals = append(s.vals, v)
}
