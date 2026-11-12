package template

import (
	"bytes"

	"example.com/template/syntax"
	"example.com/template/tplerr"
	"example.com/template/value"
)

// rendering is the state of one render of a template: the main template or
// one `include`. It keeps, per block name, the chain of block bodies from
// most to least derived.
type rendering struct {
	env      *Environment
	chains   map[string][]*syntax.Block
	tplScope *Scope
	depth    int
}

// maxDepth bounds include/extends nesting so a cycle fails cleanly.
const maxDepth = 200

func (e *Environment) newRendering(t *syntax.Template, parent *Scope, depth int) *rendering {
	r := &rendering{
		env:      e,
		chains:   make(map[string][]*syntax.Block, len(t.Blocks)),
		tplScope: newScope(parent),
		depth:    depth,
	}
	r.addBlocks(t)
	return r
}

func (r *rendering) addBlocks(t *syntax.Template) {
	for name, b := range t.Blocks {
		r.chains[name] = append(r.chains[name], b)
	}
}

// loadByExpr evaluates the name expression of an include/extends and loads
// the template it names.
func (r *rendering) loadByExpr(x syntax.Expr, sc *Scope) (*syntax.Template, error) {
	v, err := eval(x, sc)
	if err != nil {
		return nil, err
	}
	switch name := v.(type) {
	case string:
		if r.depth >= maxDepth {
			return nil, tplerr.New(tplerr.Type, "template nesting too deep")
		}
		return r.env.load(name)
	case value.UndefinedType:
		return nil, tplerr.New(tplerr.Undefined, "template name is undefined")
	}
	return nil, tplerr.New(tplerr.Type, "template name must be a string, not %T", v)
}

// runTemplate executes the body of t in the rendering's template scope.
// After an extends tag the rest of the body only runs its set and macro
// statements; then the parent template's body runs in the same scope.
func (r *rendering) runTemplate(t *syntax.Template, out *bytes.Buffer) error {
	var parent *syntax.Template
	for _, n := range t.Body {
		if parent != nil {
			switch n.(type) {
			case *syntax.Set, *syntax.MacroDef:
				if err := r.exec(n, r.tplScope, out); err != nil {
					return err
				}
			}
			continue
		}
		if ext, ok := n.(*syntax.Extends); ok {
			p, err := r.loadByExpr(ext.X, r.tplScope)
			if err != nil {
				return err
			}
			r.addBlocks(p)
			parent = p
			continue
		}
		if err := r.exec(n, r.tplScope, out); err != nil {
			return err
		}
	}
	if parent != nil {
		r.depth++
		defer func() { r.depth-- }()
		return r.runTemplate(parent, out)
	}
	return nil
}

func (r *rendering) execNodes(nodes []syntax.Node, sc *Scope, out *bytes.Buffer) error {
	for _, n := range nodes {
		if err := r.exec(n, sc, out); err != nil {
			return err
		}
	}
	return nil
}

func (r *rendering) exec(n syntax.Node, sc *Scope, out *bytes.Buffer) error {
	switch n := n.(type) {
	case *syntax.Text:
		out.WriteString(n.Text)
	case *syntax.Print:
		v, err := eval(n.X, sc)
		if err != nil {
			return err
		}
		if s, ok := v.(string); ok {
			out.WriteString(s)
			return nil
		}
		b, err := value.AppendString(out.AvailableBuffer(), v)
		if err != nil {
			return err
		}
		out.Write(b)
	case *syntax.If:
		for i, c := range n.Conds {
			v, err := eval(c, sc)
			if err != nil {
				return err
			}
			ok, err := value.Truthy(v)
			if err != nil {
				return err
			}
			if ok {
				return r.execNodes(n.Bodies[i], sc, out)
			}
		}
		return r.execNodes(n.Else, sc, out)
	case *syntax.For:
		return r.execFor(n, sc, out)
	case *syntax.Set:
		v, err := eval(n.X, sc)
		if err != nil {
			return err
		}
		sc.Set(n.Name, v)
	case *syntax.MacroDef:
		sc.Set(n.Name, &macro{def: n, scope: sc, r: r})
	case *syntax.Include:
		t, err := r.loadByExpr(n.X, sc)
		if err != nil {
			return err
		}
		sub := r.env.newRendering(t, sc, r.depth+1)
		return sub.runTemplate(t, out)
	case *syntax.Extends:
		// Handled by runTemplate; extends is only valid at the top level.
	case *syntax.Block:
		return r.renderBlock(n.Name, 0, out)
	}
	return nil
}

func (r *rendering) execFor(n *syntax.For, sc *Scope, out *bytes.Buffer) error {
	v, err := eval(n.Iter, sc)
	if err != nil {
		return err
	}
	items, err := value.Seq(v)
	if err != nil {
		return err
	}
	if len(items) == 0 {
		return r.execNodes(n.Else, sc, out)
	}
	for i, item := range items {
		inner := newScope(sc)
		inner.entries = make([]binding, 2, 4)
		inner.entries[0] = binding{n.Var, item}
		inner.entries[1] = binding{"loop", &value.Loop{Index0: i, Length: len(items)}}
		if err := r.execNodes(n.Body, inner, out); err != nil {
			return err
		}
	}
	return nil
}

// renderBlock renders entry k of the named block's chain into out.
func (r *rendering) renderBlock(name string, k int, out *bytes.Buffer) error {
	chain := r.chains[name]
	if k >= len(chain) {
		return tplerr.New(tplerr.Undefined, "no block %q to render", name)
	}
	sc := newScope(r.tplScope)
	sc.Set("super", &superFn{r: r, name: name, k: k})
	return r.execNodes(chain[k].Body, sc, out)
}

// superFn is the value bound to `super` inside a block body.
type superFn struct {
	r    *rendering
	name string
	k    int
}

func (*superFn) CallableName() string { return "super" }

func (s *superFn) call(args []value.Value, kwargs []namedArg) (value.Value, error) {
	if len(args) > 0 || len(kwargs) > 0 {
		return nil, tplerr.New(tplerr.Type, "super() takes no arguments")
	}
	if s.k+1 >= len(s.r.chains[s.name]) {
		return nil, tplerr.New(tplerr.Undefined, "super() of block %q has no parent block", s.name)
	}
	var buf bytes.Buffer
	if err := s.r.renderBlock(s.name, s.k+1, &buf); err != nil {
		return nil, err
	}
	return buf.String(), nil
}
