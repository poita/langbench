package template

import (
	"errors"
	"sync"
)

// Engine holds a set of named template sources and a cache of the templates
// loaded from them. Each template is lexed, parsed and filter-checked at
// most once, the first time it is needed. An Engine is safe for concurrent
// use.
type Engine struct {
	sources map[string]string

	mu    sync.Mutex
	cache map[string]*Template
}

// NewEngine returns an Engine serving the given template sources, keyed by
// name. The map is not copied and must not be modified afterwards.
func NewEngine(sources map[string]string) *Engine {
	return &Engine{sources: sources, cache: map[string]*Template{}}
}

// recoverError converts a panic carrying an *Error into *err; any other
// panic is re-raised.
func recoverError(err *error) {
	if p := recover(); p != nil {
		if e, ok := p.(*Error); ok {
			*err = e
			return
		}
		panic(p)
	}
}

// load returns the named template, loading it on first use. It returns an
// *Error of kind ErrTemplate for an unknown name, ErrSyntax for a template
// that does not parse and ErrFilter for an unknown filter name.
func (e *Engine) load(name string) (*Template, error) {
	e.mu.Lock()
	t, ok := e.cache[name]
	e.mu.Unlock()
	if ok {
		return t, nil
	}
	src, ok := e.sources[name]
	if !ok {
		return nil, &Error{Kind: ErrTemplate, Msg: "no template named " + name}
	}
	t, err := parseTemplate(name, src)
	if err != nil {
		return nil, err
	}
	e.mu.Lock()
	e.cache[name] = t
	e.mu.Unlock()
	return t, nil
}

func (e *Engine) mustLoad(name string) *Template {
	t, err := e.load(name)
	if err != nil {
		panic(err)
	}
	return t
}

// Render renders the named template with ctx as its initial variables and
// returns the output. ctx may be nil or a *Dict (see ParseJSON, NewDict and
// FromGo). On failure the returned error is an *Error and no partial output
// is returned.
func (e *Engine) Render(name string, ctx *Dict) (out string, err error) {
	defer recoverError(&err)
	t, err := e.load(name)
	if err != nil {
		return "", err
	}
	if ctx == nil {
		ctx = NewDict(0)
	}
	root := &scope{root: ctx}
	in := &interp{eng: e}
	buf := &output{b: make([]byte, 0, 4096)}
	newRendering(in, root).run(t, buf)
	return string(buf.b), nil
}

// Process runs the full command-line contract on input (JSON context, a
// "--" line, then "=== name" templates): it renders the first template and
// returns exactly the bytes to print on standard output, which is the
// rendering followed by a newline, or "error: <kind>\n" if rendering failed.
// A malformed input bundle is returned as an error instead.
func Process(input []byte) (string, error) {
	b, err := ParseBundle(input)
	if err != nil {
		return "", err
	}
	out, err := NewEngine(b.Sources).Render(b.Names[0], b.Context)
	if err != nil {
		var te *Error
		if errors.As(err, &te) {
			return "error: " + string(te.Kind) + "\n", nil
		}
		return "", err
	}
	return out + "\n", nil
}
