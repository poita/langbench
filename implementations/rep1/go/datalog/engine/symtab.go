package engine

import (
	"slices"

	"example.com/datalog/ast"
)

// symtab interns constants. Identifiers are assigned in ascending order of
// ast.Compare, so comparing identifiers is comparing the constants.
type symtab struct {
	ids  map[ast.Value]int32
	vals []ast.Value
}

func newSymtab(rules []ast.Rule) *symtab {
	seen := make(map[ast.Value]struct{})
	add := func(ts []ast.Term) {
		for _, t := range ts {
			if !t.IsVar {
				seen[t.Value] = struct{}{}
			}
		}
	}
	for _, r := range rules {
		add(r.Head.Args)
		for _, l := range r.Body {
			add(l.Atom.Args)
			if l.Kind == ast.Comparison {
				add([]ast.Term{l.Left, l.Right})
			}
		}
	}
	s := &symtab{ids: make(map[ast.Value]int32, len(seen))}
	for v := range seen {
		s.vals = append(s.vals, v)
	}
	slices.SortFunc(s.vals, ast.Compare)
	for i, v := range s.vals {
		s.ids[v] = int32(i)
	}
	return s
}

func (s *symtab) id(v ast.Value) (int32, bool) {
	id, ok := s.ids[v]
	return id, ok
}
