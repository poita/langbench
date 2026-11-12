package template

import (
	"bytes"
	"sync"

	"example.com/template/filters"
	"example.com/template/syntax"
	"example.com/template/tplerr"
	"example.com/template/value"
)

// Environment holds a set of named template sources and renders them.
// Templates are loaded (lexed, parsed and filter-checked) lazily, the first
// time they are needed, and at most once. An Environment is safe for
// concurrent use.
type Environment struct {
	mu      sync.Mutex
	sources map[string]string
	loaded  map[string]*syntax.Template
}

// NewEnvironment returns an empty Environment.
func NewEnvironment() *Environment {
	return &Environment{sources: map[string]string{}, loaded: map[string]*syntax.Template{}}
}

// Add registers a template source under name, replacing any previous one.
// Nothing is parsed until the template is first used.
func (e *Environment) Add(name, source string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.sources[name] = source
	delete(e.loaded, name)
}

// load returns the parsed template called name: a Template error if it does
// not exist, a Syntax error if it does not parse, a Filter error if it uses
// an unknown filter.
func (e *Environment) load(name string) (*syntax.Template, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if t, ok := e.loaded[name]; ok {
		return t, nil
	}
	src, ok := e.sources[name]
	if !ok {
		return nil, tplerr.New(tplerr.Template, "template %q not found", name)
	}
	t, err := syntax.Parse(name, src)
	if err != nil {
		return nil, err
	}
	for _, f := range t.Filters {
		if !filters.Has(f) {
			return nil, tplerr.New(tplerr.Filter, "unknown filter %q in template %q", f, name)
		}
	}
	e.loaded[name] = t
	return t, nil
}

// Render renders the template called name. ctx is the initial variables: a
// *value.Dict, a map[string]any, or nil. The output is returned only if the
// whole rendering succeeds.
func (e *Environment) Render(name string, ctx any) (string, error) {
	var root *Scope
	switch c := ctx.(type) {
	case nil:
		root = newScope(nil)
	case *value.Dict:
		root = scopeFromDict(c)
	default:
		v, err := value.FromGo(ctx)
		if err != nil {
			return "", err
		}
		d, ok := v.(*value.Dict)
		if !ok {
			return "", tplerr.New(tplerr.Type, "context must be a dict, not %T", ctx)
		}
		root = scopeFromDict(d)
	}
	t, err := e.load(name)
	if err != nil {
		return "", err
	}
	var out bytes.Buffer
	r := e.newRendering(t, root, 0)
	if err := r.runTemplate(t, &out); err != nil {
		return "", err
	}
	return out.String(), nil
}

func scopeFromDict(d *value.Dict) *Scope {
	s := newScope(nil)
	for i, k := range d.Keys() {
		s.Set(k, d.ValueAt(i))
	}
	return s
}
