package tmpl

import "strings"

// Engine holds named template sources and a cache of the templates parsed
// from them. Templates are parsed lazily, the first time a rendering needs
// them, and only once.
type Engine struct {
	sources map[string]string
	cache   map[string]*template
}

// New returns an empty engine.
func New() *Engine {
	return &Engine{sources: map[string]string{}, cache: map[string]*template{}}
}

// Add registers a template source under name, replacing any earlier
// template of that name. The source is used verbatim; nothing is trimmed.
func (e *Engine) Add(name, source string) {
	e.sources[name] = source
	delete(e.cache, name)
}

// Has reports whether a template named name is registered.
func (e *Engine) Has(name string) bool {
	_, ok := e.sources[name]
	return ok
}

// load returns the parsed template, parsing it on first use.
func (e *Engine) load(name string) *template {
	if t, ok := e.cache[name]; ok {
		return t
	}
	src, ok := e.sources[name]
	if !ok {
		fail(TemplateError, "template %q does not exist", name)
	}
	t := parseTemplate(name, src)
	e.cache[name] = t
	return t
}

// Render renders the template called name with ctx as the root scope. The
// result is all-or-nothing: on error the returned string is empty and the
// error is an *Error.
func (e *Engine) Render(name string, ctx *Dict) (result string, err error) {
	defer func() {
		if r := recover(); r != nil {
			terr, ok := r.(*Error)
			if !ok {
				panic(r)
			}
			result, err = "", terr
		}
	}()
	if ctx == nil {
		ctx = NewDict()
	}
	t := e.load(name)
	var out strings.Builder
	e.renderTemplate(t, &scope{root: ctx}, &out)
	return out.String(), nil
}
