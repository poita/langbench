package infer

import "github.com/example/typeinfer/types"

// binding is one entry of the environment: a scheme, and the binding of the
// same name that it shadows.
type binding struct {
	scheme *types.Scheme
	prev   *binding
}

// trailEntry records a shadowing so that it can be undone.
type trailEntry struct {
	name string
	prev *binding
}

// env maps each name to its innermost binding. Lookup is a single map access
// whatever the number of bindings in scope, and entering or leaving a scope
// costs O(1) per binding.
type env struct {
	m     map[string]*binding
	trail []trailEntry
}

func newEnv() *env { return &env{m: make(map[string]*binding)} }

func (e *env) lookup(name string) *types.Scheme {
	if b := e.m[name]; b != nil {
		return b.scheme
	}
	return nil
}

// push binds name, shadowing any previous binding, until the trail is
// unwound past it.
func (e *env) push(name string, s *types.Scheme) {
	prev := e.m[name]
	e.trail = append(e.trail, trailEntry{name, prev})
	e.m[name] = &binding{scheme: s, prev: prev}
}

// mark returns a position in the trail to unwind to.
func (e *env) mark() int { return len(e.trail) }

// unwind removes every binding pushed since mark.
func (e *env) unwind(mark int) {
	for i := len(e.trail) - 1; i >= mark; i-- {
		t := e.trail[i]
		if t.prev == nil {
			delete(e.m, t.name)
		} else {
			e.m[t.name] = t.prev
		}
	}
	e.trail = e.trail[:mark]
}

// commit makes every binding pushed since mark permanent.
func (e *env) commit(mark int) { e.trail = e.trail[:mark] }
