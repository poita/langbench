package template

import "example.com/template/value"

type binding struct {
	name string
	val  value.Value
}

// Scope maps names to values and has a parent scope. Creating one is O(1);
// a lookup walks the chain of scopes.
type Scope struct {
	parent  *Scope
	entries []binding
	index   map[string]int // built once the scope grows large
}

const scopeIndexThreshold = 12

func newScope(parent *Scope) *Scope { return &Scope{parent: parent} }

// Lookup returns the value bound to name in s or the nearest ancestor.
func (s *Scope) Lookup(name string) (value.Value, bool) {
	for ; s != nil; s = s.parent {
		if s.index != nil {
			if i, ok := s.index[name]; ok {
				return s.entries[i].val, true
			}
			continue
		}
		for i := range s.entries {
			if s.entries[i].name == name {
				return s.entries[i].val, true
			}
		}
	}
	return nil, false
}

// Set binds name in s itself (never in an ancestor).
func (s *Scope) Set(name string, v value.Value) {
	if s.index != nil {
		if i, ok := s.index[name]; ok {
			s.entries[i].val = v
			return
		}
	} else {
		for i := range s.entries {
			if s.entries[i].name == name {
				s.entries[i].val = v
				return
			}
		}
	}
	s.entries = append(s.entries, binding{name, v})
	switch {
	case s.index != nil:
		s.index[name] = len(s.entries) - 1
	case len(s.entries) > scopeIndexThreshold:
		s.index = make(map[string]int, len(s.entries)*2)
		for i, e := range s.entries {
			s.index[e.name] = i
		}
	}
}
