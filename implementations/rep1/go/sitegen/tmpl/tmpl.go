// Package tmpl implements a small Jinja-style template language.
//
// The language has {{ expressions }}, {% statements %} and {# comments #};
// whitespace control with "-"; the statements if/elif/else, for/else, set,
// macro, include, extends and block (with super()); the usual operators; and
// the filters upper, lower, trim, escape, replace, length, int, join, first,
// last, reverse, sort and default. Autoescaping is off. Referencing an
// undefined name is an error rather than an empty string.
//
// A Set holds named template sources. Templates are parsed lazily, once, the
// first time a rendering needs them:
//
//	set := tmpl.NewSet()
//	set.Add("base.html", "<title>{% block title %}{% endblock %}</title>")
//	set.Add("page.html", `{% extends "base.html" %}{% block title %}{{ name|upper }}{% endblock %}`)
//	out, err := set.Render("page.html", map[string]tmpl.Value{"name": "hello"})
//
// Errors are *Error values whose Kind says which category of failure occurred.
package tmpl

import "sync"

// A Set is a collection of named templates that can include and extend each
// other. A Set is safe for concurrent use by multiple goroutines.
type Set struct {
	mu     sync.Mutex
	src    map[string]string
	loaded map[string]*loadResult
}

type loadResult struct {
	t   *template
	err *Error
}

// NewSet returns an empty Set.
func NewSet() *Set {
	return &Set{src: map[string]string{}, loaded: map[string]*loadResult{}}
}

// Add registers the template called name, replacing any earlier template of
// that name. The source is used verbatim: a trailing newline is part of the
// template.
func (s *Set) Add(name, source string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.src[name] = source
	delete(s.loaded, name)
}

// load returns the parsed template called name, parsing and checking it on
// first use. It panics with an *Error on failure.
func (s *Set) load(name string) *template {
	s.mu.Lock()
	res, ok := s.loaded[name]
	if !ok {
		src, found := s.src[name]
		if !found {
			s.mu.Unlock()
			throw(KindTemplate, "template %q not found", name)
		}
		res = s.parseLocked(name, src)
		s.loaded[name] = res
	}
	s.mu.Unlock()
	if res.err != nil {
		panic(res.err)
	}
	return res.t
}

func (s *Set) parseLocked(name, src string) (res *loadResult) {
	res = &loadResult{}
	defer func() {
		if e := recover(); e != nil {
			err, ok := e.(*Error)
			if !ok {
				panic(e)
			}
			res.err = err
		}
	}()
	res.t = parseTemplate(name, src)
	return res
}

// Render renders the template called name with vars as its root scope. The
// map is read but never modified. On failure the returned error is an *Error
// and no partial output is returned.
func (s *Set) Render(name string, vars map[string]Value) (result string, err error) {
	defer func() {
		if e := recover(); e != nil {
			te, ok := e.(*Error)
			if !ok {
				panic(e)
			}
			result, err = "", te
		}
	}()
	t := s.load(name)
	root := &scope{m: vars}
	if root.m == nil {
		root.m = map[string]Value{}
	}
	out := &outbuf{b: make([]byte, 0, 1024)}
	s.runTemplate(t, root, out)
	return string(out.b), nil
}
